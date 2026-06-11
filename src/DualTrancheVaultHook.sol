// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IERC4626} from "openzeppelin/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ImmutableState} from "v4-periphery/base/ImmutableState.sol";

import {SeniorShares} from "./SeniorShares.sol";
import {JuniorShares} from "./JuniorShares.sol";
import {IVolatilityOracle} from "./interfaces/IVolatilityOracle.sol";

/// @title DualTrancheVaultHook
/// @notice Volatility-gated tranched liquidity with idle-capital lending.
///
/// Senior tranche  — always open, 30% fee share, idle capital routes to ERC4626 vault.
/// Junior tranche  — vol-gated entry, 70% fee share, 10% vault-yield boost when out-of-range.
///
/// Hook flags required (encode in address):
///   AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY
///   | BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | AFTER_SWAP
///
/// @dev Capital routing to the vault is triggered by calling rebalance(key).
///      afterSwap updates the routing state; actual token movement is explicit
///      so it stays out of the swap critical path.
contract DualTrancheVaultHook is IHooks, ImmutableState {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // ── Errors ──────────────────────────────────────────────────────────────

    error JuniorGateClosed(uint256 currentVol, uint256 threshold);
    error VaultNotApproved(address vault);
    error NotAuthorized();
    error NoCapitalToRoute();
    error VaultAlreadySet();

    // ── Events ───────────────────────────────────────────────────────────────

    event JuniorGateOpened(PoolId indexed poolId, uint256 currentVol);
    event JuniorGateSealed(PoolId indexed poolId, uint256 currentVol);
    event CapitalRoutedToVault(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event CapitalRecalledFromVault(PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 yieldEarned);
    event FeesDistributed(PoolId indexed poolId, uint256 seniorAmount, uint256 juniorAmount);
    event VaultApproved(address indexed vault);

    // ── Storage ───────────────────────────────────────────────────────────────

    struct PoolState {
        bool capitalInVault;
        uint256 vaultShares0; // ERC4626 shares held for currency0
        uint256 depositedAmount0; // principal deposited into vault (currency0)
        uint256 depositedAmount1; // principal deposited into vault (currency1)
        int24 seniorTickLower; // Senior LP range lower tick
        int24 seniorTickUpper; // Senior LP range upper tick
        uint256 juniorVolThreshold; // gate closes when vol >= this (bps)
        bool juniorGateOpen;
        address vault; // ERC4626 vault (currency0-denominated)
    }

    struct TrancheAccounting {
        uint256 seniorFeePool; // cumulative 30% fee share (estimated, in currency0 terms)
        uint256 juniorFeePool; // cumulative 70% fee share
        uint256 vaultYieldPool; // 90% of vault yield → Seniors
        uint256 juniorBoostPool; // 10% of vault yield → Juniors
        // Reward-per-share index accounting (scaled by 1e18)
        uint256 seniorRewardPerShare;
        uint256 juniorRewardPerShare;
        mapping(address => uint256) seniorDebt;
        mapping(address => uint256) juniorDebt;
    }

    mapping(PoolId => PoolState) public poolStates;
    mapping(PoolId => TrancheAccounting) internal _accounting;
    mapping(PoolId => SeniorShares) public seniorShareTokens;
    mapping(PoolId => JuniorShares) public juniorShareTokens;
    mapping(address => bool) public approvedVaults;

    IVolatilityOracle public immutable volOracle;
    address public immutable owner;

    // 30 bps → Senior; 70 bps → Junior (out of 100 bps)
    uint256 public constant SENIOR_FEE_SHARE_BPS = 3000;
    uint256 public constant JUNIOR_FEE_SHARE_BPS = 7000;
    // 10% of vault yield goes to Junior as volatility-risk compensation
    uint256 public constant JUNIOR_VAULT_BOOST_BPS = 1000;
    uint256 public constant BPS = 10_000;
    uint256 public constant PRECISION = 1e18;

    // Minimum liquidity delta (in bps scaled) to trigger routing
    uint256 public constant MIN_ROUTING_AMOUNT = 1e6;

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager, IVolatilityOracle _volOracle) ImmutableState(_poolManager) {
        volOracle = _volOracle;
        owner = msg.sender;
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function approveVault(address vault) external {
        if (msg.sender != owner) revert NotAuthorized();
        approvedVaults[vault] = true;
        emit VaultApproved(vault);
    }

    // ── IHooks: Hook Permissions ─────────────────────────────────────────────

    /// @notice Returns the hook permissions bitmask. Used off-chain for address mining.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ── IHooks: afterInitialize ──────────────────────────────────────────────

    /// @notice Deploys share tokens and initialises pool state.
    /// @dev hookData = abi.encode(vault, juniorVolThreshold, tickLower, tickUpper)
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    /// @notice Called by the pool deployer immediately after pool initialisation.
    /// @param key         The pool key.
    /// @param vault       Approved ERC4626 vault address.
    /// @param juniorVolThreshold Vol threshold in bps (e.g. 5000 = 50%).
    /// @param tickLower   Lower tick of the Senior LP range.
    /// @param tickUpper   Upper tick of the Senior LP range.
    function initPool(PoolKey calldata key, address vault, uint256 juniorVolThreshold, int24 tickLower, int24 tickUpper)
        external
    {
        if (!approvedVaults[vault]) revert VaultNotApproved(vault);
        PoolId id = key.toId();
        if (address(seniorShareTokens[id]) != address(0)) revert VaultAlreadySet();

        string memory sym = _poolSymbol(key);

        seniorShareTokens[id] = new SeniorShares(
            address(this), string(abi.encodePacked("Senior-", sym)), string(abi.encodePacked("sLP-", sym))
        );
        juniorShareTokens[id] = new JuniorShares(
            address(this), string(abi.encodePacked("Junior-", sym)), string(abi.encodePacked("jLP-", sym))
        );

        poolStates[id] = PoolState({
            capitalInVault: false,
            vaultShares0: 0,
            depositedAmount0: 0,
            depositedAmount1: 0,
            seniorTickLower: tickLower,
            seniorTickUpper: tickUpper,
            juniorVolThreshold: juniorVolThreshold,
            juniorGateOpen: true,
            vault: vault
        });
    }

    // ── IHooks: beforeAddLiquidity — Volatility Gate ─────────────────────────

    /// @notice Blocks Junior LP deposits when 24h realised vol exceeds threshold.
    /// @dev hookData = abi.encode(bool isSenior, address lp)
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        (bool isSenior,) = abi.decode(hookData, (bool, address));
        if (isSenior) return IHooks.beforeAddLiquidity.selector;

        PoolId id = key.toId();
        PoolState storage state = poolStates[id];

        uint256 currentVol = _safeGetVol(key);

        if (currentVol >= state.juniorVolThreshold) {
            if (state.juniorGateOpen) {
                state.juniorGateOpen = false;
                emit JuniorGateSealed(id, currentVol);
            }
            revert JuniorGateClosed(currentVol, state.juniorVolThreshold);
        }

        if (!state.juniorGateOpen) {
            state.juniorGateOpen = true;
            emit JuniorGateOpened(id, currentVol);
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    // ── IHooks: afterAddLiquidity — Mint Shares ───────────────────────────────

    /// @notice Mints Senior or Junior shares proportional to the liquidity added.
    /// @dev hookData = abi.encode(bool isSenior, address lp) — lp is the recipient of shares.
    ///      The `sender` param is the router (msg.sender of modifyLiquidity), not the LP.
    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        (bool isSenior, address lp) = abi.decode(hookData, (bool, address));
        PoolId id = key.toId();

        // liquidityDelta is always positive here (add liquidity)
        uint256 shareAmount = uint256(params.liquidityDelta);

        if (isSenior) {
            _settleRewardDebt(id, lp, true);
            seniorShareTokens[id].mint(lp, shareAmount);
        } else {
            _settleRewardDebt(id, lp, false);
            juniorShareTokens[id].mint(lp, shareAmount);
        }

        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // ── IHooks: beforeRemoveLiquidity ─────────────────────────────────────────

    /// @notice If Senior LP is withdrawing while capital is in vault, recall it first.
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        (bool isSenior,) = abi.decode(hookData, (bool, address));
        PoolId id = key.toId();
        PoolState storage state = poolStates[id];

        if (isSenior && state.capitalInVault) {
            _recallCapitalFromVault(key, id, state);
        }

        return IHooks.beforeRemoveLiquidity.selector;
    }

    // ── IHooks: afterRemoveLiquidity — Burn Shares ────────────────────────────

    /// @notice Burns shares on withdrawal, distributing any pending rewards first.
    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        (bool isSenior, address lp) = abi.decode(hookData, (bool, address));
        PoolId id = key.toId();

        uint256 sharesToBurn = uint256(-params.liquidityDelta);

        if (isSenior) {
            _settleRewardDebt(id, lp, true);
            seniorShareTokens[id].burn(lp, sharesToBurn);
        } else {
            _settleRewardDebt(id, lp, false);
            juniorShareTokens[id].burn(lp, sharesToBurn);
        }

        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // ── IHooks: afterSwap — Fee Split + Range Check ──────────────────────────

    /// @notice Splits estimated swap fees 30/70 between tranches and checks
    ///         whether Senior capital should be routed to/recalled from the vault.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();

        // 1. Estimate fee earned by LPs this swap and split 30 / 70
        uint256 totalFee = _estimateFee(params, delta, key.fee);
        if (totalFee > 0) {
            TrancheAccounting storage acct = _accounting[id];
            uint256 seniorFee = (totalFee * SENIOR_FEE_SHARE_BPS) / BPS;
            uint256 juniorFee = totalFee - seniorFee;

            SeniorShares sToken = seniorShareTokens[id];
            JuniorShares jToken = juniorShareTokens[id];

            uint256 sTotalSupply = sToken.totalSupply();
            uint256 jTotalSupply = jToken.totalSupply();

            if (sTotalSupply > 0) {
                acct.seniorRewardPerShare += (seniorFee * PRECISION) / sTotalSupply;
                acct.seniorFeePool += seniorFee;
            }
            if (jTotalSupply > 0) {
                acct.juniorRewardPerShare += (juniorFee * PRECISION) / jTotalSupply;
                acct.juniorFeePool += juniorFee;
            }

            emit FeesDistributed(id, seniorFee, juniorFee);
        }

        // 2. Check range and update routing state flag (actual routing is explicit)
        _updateRoutingState(key, id);

        return (IHooks.afterSwap.selector, 0);
    }

    // ── Unsupported hook callbacks ────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    error HookNotImplemented();

    // ── Capital Routing (explicit) ────────────────────────────────────────────

    /// @notice Routes idle Senior capital to the vault when out of range,
    ///         or recalls capital when price re-enters range.
    /// @dev Anyone can call; rebalance is safe to call at any time.
    function rebalance(PoolKey calldata key) external {
        PoolId id = key.toId();
        PoolState storage state = poolStates[id];

        bool inRange = _isSeniorCapitalInRange(key, id);

        if (!inRange && !state.capitalInVault) {
            _routeCapitalToVault(key, id, state);
        } else if (inRange && state.capitalInVault) {
            _recallCapitalFromVault(key, id, state);
        }
    }

    // ── Yield Claims ─────────────────────────────────────────────────────────

    /// @notice Claims the caller's pro-rata share of Senior fee + vault yield.
    function claimSeniorYield(PoolKey calldata key) external returns (uint256 total) {
        PoolId id = key.toId();
        SeniorShares shares = seniorShareTokens[id];
        TrancheAccounting storage acct = _accounting[id];

        uint256 balance = shares.balanceOf(msg.sender);
        if (balance == 0) return 0;

        uint256 pending = _pendingSenior(id, msg.sender, balance);
        if (pending == 0) return 0;

        // Settle debt
        acct.seniorDebt[msg.sender] = (balance * acct.seniorRewardPerShare) / PRECISION;

        // Deduct from pool (clamp to avoid underflow from rounding)
        if (pending > acct.seniorFeePool + acct.vaultYieldPool) {
            pending = acct.seniorFeePool + acct.vaultYieldPool;
        }
        uint256 fromFees = pending <= acct.seniorFeePool ? pending : acct.seniorFeePool;
        uint256 fromVault = pending - fromFees;
        acct.seniorFeePool -= fromFees;
        if (fromVault > acct.vaultYieldPool) fromVault = acct.vaultYieldPool;
        acct.vaultYieldPool -= fromVault;

        total = fromFees + fromVault;
        if (total == 0) return 0;

        // Transfer currency0 to caller
        Currency c0 = key.currency0;
        c0.transfer(msg.sender, total);
    }

    /// @notice Claims the caller's pro-rata share of Junior fee + vault boost.
    function claimJuniorYield(PoolKey calldata key) external returns (uint256 total) {
        PoolId id = key.toId();
        JuniorShares shares = juniorShareTokens[id];
        TrancheAccounting storage acct = _accounting[id];

        uint256 balance = shares.balanceOf(msg.sender);
        if (balance == 0) return 0;

        uint256 pending = _pendingJunior(id, msg.sender, balance);
        if (pending == 0) return 0;

        acct.juniorDebt[msg.sender] = (balance * acct.juniorRewardPerShare) / PRECISION;

        if (pending > acct.juniorFeePool + acct.juniorBoostPool) {
            pending = acct.juniorFeePool + acct.juniorBoostPool;
        }
        uint256 fromFees = pending <= acct.juniorFeePool ? pending : acct.juniorFeePool;
        uint256 fromBoost = pending - fromFees;
        acct.juniorFeePool -= fromFees;
        if (fromBoost > acct.juniorBoostPool) fromBoost = acct.juniorBoostPool;
        acct.juniorBoostPool -= fromBoost;

        total = fromFees + fromBoost;
        if (total == 0) return 0;

        key.currency0.transfer(msg.sender, total);
    }

    // ── Admin: Tick Range Update ──────────────────────────────────────────────

    /// @notice Updates the Senior LP tick range. Only callable by owner.
    function updateSeniorRange(PoolId id, int24 tickLower, int24 tickUpper) external {
        if (msg.sender != owner) revert NotAuthorized();
        PoolState storage state = poolStates[id];
        state.seniorTickLower = tickLower;
        state.seniorTickUpper = tickUpper;
    }

    // ── View Functions ────────────────────────────────────────────────────────

    function getPoolState(PoolId id) external view returns (PoolState memory) {
        return poolStates[id];
    }

    /// @notice Returns the live gate status by querying the oracle.
    /// @dev Non-view because the real oracle updates its cache.
    function isJuniorGateOpen(PoolKey calldata key) external returns (bool) {
        PoolId id = key.toId();
        uint256 currentVol = _safeGetVol(key);
        return currentVol < poolStates[id].juniorVolThreshold;
    }

    /// @notice Returns the last-stored gate state (may be stale after failed deposits).
    function juniorGateOpenStored(PoolKey calldata key) external view returns (bool) {
        return poolStates[key.toId()].juniorGateOpen;
    }

    function pendingSeniorYield(PoolKey calldata key, address lp) external view returns (uint256) {
        PoolId id = key.toId();
        uint256 balance = seniorShareTokens[id].balanceOf(lp);
        return _pendingSenior(id, lp, balance);
    }

    function pendingJuniorYield(PoolKey calldata key, address lp) external view returns (uint256) {
        PoolId id = key.toId();
        uint256 balance = juniorShareTokens[id].balanceOf(lp);
        return _pendingJunior(id, lp, balance);
    }

    function getTrancheAccounting(PoolKey calldata key)
        external
        view
        returns (uint256 seniorFeePool, uint256 juniorFeePool, uint256 vaultYieldPool, uint256 juniorBoostPool)
    {
        PoolId id = key.toId();
        TrancheAccounting storage acct = _accounting[id];
        return (acct.seniorFeePool, acct.juniorFeePool, acct.vaultYieldPool, acct.juniorBoostPool);
    }

    // ── Internal: Capital Routing ─────────────────────────────────────────────

    function _routeCapitalToVault(PoolKey calldata key, PoolId id, PoolState storage state) internal {
        address vaultAddr = state.vault;

        // Pull the ERC20 token balance that the hook holds directly.
        // In a full implementation: remove hook's LP position, take tokens, deposit.
        // Here we move whatever currency0 the hook already holds (funded by LP deposits).
        address token0 = Currency.unwrap(key.currency0);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        if (balance0 < MIN_ROUTING_AMOUNT) revert NoCapitalToRoute();

        IERC20(token0).approve(vaultAddr, balance0);
        uint256 sharesReceived = IERC4626(vaultAddr).deposit(balance0, address(this));

        state.capitalInVault = true;
        state.vaultShares0 = sharesReceived;
        state.depositedAmount0 = balance0;

        emit CapitalRoutedToVault(id, balance0, 0);
    }

    function _recallCapitalFromVault(PoolKey calldata, PoolId id, PoolState storage state) internal {
        if (state.vaultShares0 == 0) {
            state.capitalInVault = false;
            return;
        }

        uint256 redeemed = IERC4626(state.vault).redeem(state.vaultShares0, address(this), address(this));
        uint256 principal = state.depositedAmount0;
        uint256 yieldEarned = redeemed > principal ? redeemed - principal : 0;

        if (yieldEarned > 0) {
            TrancheAccounting storage acct = _accounting[id];
            uint256 juniorBoost = (yieldEarned * JUNIOR_VAULT_BOOST_BPS) / BPS;
            uint256 seniorYield = yieldEarned - juniorBoost;

            SeniorShares sToken = seniorShareTokens[id];
            JuniorShares jToken = juniorShareTokens[id];
            uint256 sTotalSupply = sToken.totalSupply();
            uint256 jTotalSupply = jToken.totalSupply();

            if (sTotalSupply > 0) {
                acct.seniorRewardPerShare += (seniorYield * PRECISION) / sTotalSupply;
                acct.vaultYieldPool += seniorYield;
            }
            if (jTotalSupply > 0) {
                acct.juniorRewardPerShare += (juniorBoost * PRECISION) / jTotalSupply;
                acct.juniorBoostPool += juniorBoost;
            }
        }

        state.capitalInVault = false;
        state.vaultShares0 = 0;
        state.depositedAmount0 = 0;

        emit CapitalRecalledFromVault(id, redeemed, 0, yieldEarned);
    }

    // ── Internal: Routing State Update ────────────────────────────────────────

    function _updateRoutingState(PoolKey calldata key, PoolId id) internal view {
        // Routing state is observed here; keepers call rebalance() to act on it.
        // This function is a hook for future on-chain auto-routing extensions.
        _isSeniorCapitalInRange(key, id);
    }

    function _isSeniorCapitalInRange(PoolKey calldata key, PoolId id) internal view returns (bool) {
        PoolState storage state = poolStates[id];
        (, int24 currentTick,,) = poolManager.getSlot0(id);
        return currentTick >= state.seniorTickLower && currentTick < state.seniorTickUpper;
    }

    // ── Internal: Fee Estimation ──────────────────────────────────────────────

    /// @dev Estimates LP fee earned from this swap.
    ///      fee = |input_amount| * fee_rate_ppm
    function _estimateFee(IPoolManager.SwapParams calldata params, BalanceDelta delta, uint24 feePpm)
        internal
        pure
        returns (uint256)
    {
        int128 inputAmount;
        if (params.zeroForOne) {
            // currency0 is the input (negative delta = user pays)
            inputAmount = delta.amount0();
        } else {
            inputAmount = delta.amount1();
        }
        if (inputAmount >= 0) return 0;
        uint256 absInput = uint256(uint128(-inputAmount));
        return (absInput * feePpm) / 1_000_000;
    }

    // ── Internal: Reward Accounting ───────────────────────────────────────────

    function _pendingSenior(PoolId id, address lp, uint256 balance) internal view returns (uint256) {
        if (balance == 0) return 0;
        TrancheAccounting storage acct = _accounting[id];
        uint256 accumulated = (balance * acct.seniorRewardPerShare) / PRECISION;
        uint256 debt = acct.seniorDebt[lp];
        return accumulated > debt ? accumulated - debt : 0;
    }

    function _pendingJunior(PoolId id, address lp, uint256 balance) internal view returns (uint256) {
        if (balance == 0) return 0;
        TrancheAccounting storage acct = _accounting[id];
        uint256 accumulated = (balance * acct.juniorRewardPerShare) / PRECISION;
        uint256 debt = acct.juniorDebt[lp];
        return accumulated > debt ? accumulated - debt : 0;
    }

    function _settleRewardDebt(PoolId id, address lp, bool isSenior) internal {
        TrancheAccounting storage acct = _accounting[id];
        if (isSenior) {
            uint256 balance = seniorShareTokens[id].balanceOf(lp);
            acct.seniorDebt[lp] = (balance * acct.seniorRewardPerShare) / PRECISION;
        } else {
            uint256 balance = juniorShareTokens[id].balanceOf(lp);
            acct.juniorDebt[lp] = (balance * acct.juniorRewardPerShare) / PRECISION;
        }
    }

    // ── Internal: Helpers ─────────────────────────────────────────────────────

    function _safeGetVol(PoolKey calldata key) internal returns (uint256) {
        try volOracle.getAnnualizedVol(key.currency0, key.currency1) returns (uint256 vol) {
            // Oracle failure fallback: gate defaults to CLOSED (conservative)
            if (vol == type(uint256).max) return type(uint256).max;
            return vol;
        } catch {
            return type(uint256).max; // treat oracle failure as gate closed
        }
    }

    function _poolSymbol(PoolKey calldata key) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked(_toHex(Currency.unwrap(key.currency0)), "-", _toHex(Currency.unwrap(key.currency1)))
            );
    }

    function _toHex(address addr) internal pure returns (string memory) {
        bytes memory b = abi.encodePacked(addr);
        bytes memory hex_ = new bytes(8);
        bytes memory alphabet = "0123456789abcdef";
        for (uint256 i = 0; i < 4; i++) {
            hex_[i * 2] = alphabet[uint8(b[i] >> 4)];
            hex_[i * 2 + 1] = alphabet[uint8(b[i] & 0x0f)];
        }
        return string(hex_);
    }
}
