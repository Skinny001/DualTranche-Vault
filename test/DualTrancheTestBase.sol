// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {DualTrancheVaultHook} from "../src/DualTrancheVaultHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626Vault} from "./mocks/MockERC4626Vault.sol";
import {MockVolatilityOracle} from "./mocks/MockVolatilityOracle.sol";

/// @notice Shared test setup for DualTrancheVaultHook tests.
abstract contract DualTrancheTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ── Required hook flags ───────────────────────────────────────────────────
    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    // ── Pool constants ────────────────────────────────────────────────────────
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // sqrt(1) in Q96
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000; // 0.3 %
    int24 constant TICK_LOWER = -120;
    int24 constant TICK_UPPER = 120;
    uint256 constant DEFAULT_VOL = 3000; // 30% — below 50% threshold
    uint256 constant HIGH_VOL = 6000; // 60% — above 50% threshold
    uint256 constant VOL_THRESHOLD = 5000; // 50%

    // ── Contracts ─────────────────────────────────────────────────────────────
    IPoolManager public manager;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    PoolSwapTest public swapRouter;

    DualTrancheVaultHook public hook;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC4626Vault public vault;
    MockVolatilityOracle public oracle;

    PoolKey public key;
    PoolId public poolId;

    // ── Test actors ───────────────────────────────────────────────────────────
    address internal seniorLP = makeAddr("seniorLP");
    address internal juniorLP = makeAddr("juniorLP");
    address internal swapper = makeAddr("swapper");
    address internal deployer = makeAddr("deployer");

    function setUp() public virtual {
        // 1. Deploy PoolManager + routers
        manager = new PoolManager(address(this));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        // 2. Deploy tokens (sorted by address)
        MockERC20 tA = new MockERC20("TokenA", "TKA", 18);
        MockERC20 tB = new MockERC20("TokenB", "TKB", 18);
        if (address(tA) < address(tB)) {
            token0 = tA;
            token1 = tB;
        } else {
            token0 = tB;
            token1 = tA;
        }

        // 3. Deploy mock vault (token0-denominated)
        vault = new MockERC4626Vault(address(token0));

        // 4. Deploy mock oracle (low vol by default)
        oracle = new MockVolatilityOracle(DEFAULT_VOL);

        // 5. Deploy hook at the mined address
        DualTrancheVaultHook impl = new DualTrancheVaultHook(manager, oracle);
        address hookAddr = address(FLAGS);
        vm.etch(hookAddr, address(impl).code);
        // Restore immutables by re-constructing at the right address
        // vm.etch copies bytecode but immutables are baked in — we need to
        // store them via the constructor pattern:
        _deployHookAtAddress(hookAddr);

        hook = DualTrancheVaultHook(hookAddr);

        // 6. Approve vault
        vm.prank(hook.owner());
        hook.approveVault(address(vault));

        // 7. Init pool
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        poolId = key.toId();

        // 8. Finish hook setup (share token deployment, range registration)
        hook.initPool(key, address(vault), VOL_THRESHOLD, TICK_LOWER, TICK_UPPER);

        // 9. Fund actors
        _fundAndApprove(seniorLP, 100_000e18);
        _fundAndApprove(juniorLP, 100_000e18);
        _fundAndApprove(swapper, 100_000e18);
        _fundAndApprove(address(this), 100_000e18);
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    /// @dev Deploys the hook with correct immutables at the given address via CREATE2-workaround.
    function _deployHookAtAddress(address hookAddr) internal {
        // Using vm.etch copies deployed bytecode (including baked-in immutables).
        // We create the implementation, then etch it — immutables travel with the code.
        DualTrancheVaultHook impl2 = new DualTrancheVaultHook(manager, oracle);
        vm.etch(hookAddr, address(impl2).code);
    }

    function _fundAndApprove(address user, uint256 amount) internal {
        token0.mint(user, amount);
        token1.mint(user, amount);
        vm.startPrank(user);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _addSeniorLiquidity(address lp, int256 liquidity) internal returns (BalanceDelta delta) {
        vm.prank(lp);
        delta = modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidity, salt: 0
            }),
            abi.encode(true, lp) // isSenior=true, lp=recipient
        );
    }

    function _addJuniorLiquidity(address lp, int256 liquidity) internal returns (BalanceDelta delta) {
        vm.prank(lp);
        delta = modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidity, salt: 0
            }),
            abi.encode(false, lp) // isSenior=false, lp=recipient
        );
    }

    function _removeLiquidity(address lp, int256 liquidity, bool isSenior) internal returns (BalanceDelta delta) {
        vm.prank(lp);
        delta = modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -liquidity, salt: 0
            }),
            abi.encode(isSenior, lp) // include lp for burn
        );
    }

    function _swap(address user, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        vm.prank(user);
        return swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
