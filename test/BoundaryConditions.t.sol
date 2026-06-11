// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ImmutableState} from "v4-periphery/base/ImmutableState.sol";

import {DualTrancheTestBase} from "./DualTrancheTestBase.sol";
import {DualTrancheVaultHook} from "../src/DualTrancheVaultHook.sol";
import {SeniorShares} from "../src/SeniorShares.sol";

/// @notice Boundary conditions, failure paths, and non-PoolManager call security tests.
contract BoundaryConditionsTest is DualTrancheTestBase {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // ── Vol gate — exact threshold boundary ──────────────────────────────────

    function test_Gate_ExactlyAtThreshold_IsBlocked() public {
        // vol == threshold → condition is (vol >= threshold) → CLOSED
        oracle.setVol(VOL_THRESHOLD);
        vm.expectRevert();
        _addJuniorLiquidity(juniorLP, 1e18);
    }

    function test_Gate_OneBelowThreshold_IsAllowed() public {
        oracle.setVol(VOL_THRESHOLD - 1);
        _addJuniorLiquidity(juniorLP, 1e18);
        assertGt(hook.juniorShareTokens(poolId).balanceOf(juniorLP), 0);
    }

    function test_Gate_ZeroVol_AlwaysOpen() public {
        oracle.setVol(0);
        _addJuniorLiquidity(juniorLP, 1e18);
        assertGt(hook.juniorShareTokens(poolId).balanceOf(juniorLP), 0);
    }

    function test_Gate_MaxUint256Vol_AlwaysClosed() public {
        oracle.setVol(type(uint256).max);
        vm.expectRevert();
        _addJuniorLiquidity(juniorLP, 1e18);
    }

    function test_Gate_SeniorNeverBlocked_AtExactThreshold() public {
        oracle.setVol(VOL_THRESHOLD); // exactly at threshold
        _addSeniorLiquidity(seniorLP, 1e18);
        assertGt(hook.seniorShareTokens(poolId).balanceOf(seniorLP), 0);
    }

    function test_Gate_SeniorNeverBlocked_AboveThreshold() public {
        oracle.setVol(VOL_THRESHOLD + 1);
        _addSeniorLiquidity(seniorLP, 1e18);
        assertGt(hook.seniorShareTokens(poolId).balanceOf(seniorLP), 0);
    }

    // ── Fee distribution — only one tranche has liquidity ────────────────────

    function test_Fees_OnlySenior_JuniorPoolStaysZero() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _swap(swapper, true, -1e14);
        _swap(swapper, false, -1e14);

        (, uint256 juniorFees,,) = hook.getTrancheAccounting(key);
        assertEq(juniorFees, 0, "Junior pool must be 0 with no Junior LPs");
    }

    function test_Fees_OnlyJunior_SeniorPoolStaysZero() public {
        _addJuniorLiquidity(juniorLP, 10e18);
        _swap(swapper, true, -1e14);
        _swap(swapper, false, -1e14);

        (uint256 seniorFees,,,) = hook.getTrancheAccounting(key);
        assertEq(seniorFees, 0, "Senior pool must be 0 with no Senior LPs");
    }

    function test_Fees_DoubleClaim_Senior_SecondReturnsZero() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _swap(swapper, true, -1e14);
        token0.mint(address(hook), 1e18);

        vm.prank(seniorLP);
        uint256 first = hook.claimSeniorYield(key);

        vm.prank(seniorLP);
        uint256 second = hook.claimSeniorYield(key);

        assertGt(first, 0, "First claim should yield tokens");
        assertEq(second, 0, "Second claim should be exhausted");
    }

    function test_Fees_DoubleClaim_Junior_SecondReturnsZero() public {
        _addJuniorLiquidity(juniorLP, 10e18);
        _swap(swapper, true, -1e14);
        token0.mint(address(hook), 1e18);

        vm.prank(juniorLP);
        uint256 first = hook.claimJuniorYield(key);

        vm.prank(juniorLP);
        uint256 second = hook.claimJuniorYield(key);

        assertGt(first, 0);
        assertEq(second, 0);
    }

    function test_Fees_Claim_AddressWithNoShares_ReturnsZero() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _swap(swapper, true, -1e14);

        address noShares = makeAddr("noShares");
        vm.prank(noShares);
        assertEq(hook.claimSeniorYield(key), 0);

        vm.prank(noShares);
        assertEq(hook.claimJuniorYield(key), 0);
    }

    function test_Fees_ClaimAfterShareTransfer_NewHolderAccrues() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _swap(swapper, true, -1e14);

        address recipient = makeAddr("recipient");
        // Cache share token + balance before prank — getter calls consume prank if called as args.
        SeniorShares sT = hook.seniorShareTokens(poolId);
        uint256 balance = sT.balanceOf(seniorLP);
        vm.prank(seniorLP);
        sT.transfer(recipient, balance);

        // New swaps — recipient should accrue
        _swap(swapper, false, -1e14);
        uint256 pending = hook.pendingSeniorYield(key, recipient);
        assertGt(pending, 0, "New holder accrues yield after swap");
    }

    function test_Fees_BothTranches_SumConsistent() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        _swap(swapper, true, -1e14);
        _swap(swapper, false, -1e14);

        (uint256 sf, uint256 jf,,) = hook.getTrancheAccounting(key);

        assertGt(sf, 0);
        assertGt(jf, 0);
        // Junior pool should be larger (70% share)
        assertGt(jf, sf, "Junior 70% > Senior 30%");
    }

    // ── Capital routing — amount boundary ────────────────────────────────────

    function test_Route_ExactlyMinAmount_Succeeds() public {
        uint256 minAmt = hook.MIN_ROUTING_AMOUNT();
        token0.mint(address(hook), minAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));

        hook.rebalance(key);
        assertTrue(hook.getPoolState(poolId).capitalInVault);
    }

    function test_Route_OneBelowMinAmount_Reverts() public {
        uint256 minAmt = hook.MIN_ROUTING_AMOUNT();
        vm.assume(minAmt > 0);
        token0.mint(address(hook), minAmt - 1);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));

        vm.expectRevert(DualTrancheVaultHook.NoCapitalToRoute.selector);
        hook.rebalance(key);
    }

    function test_Route_DoubleRebalance_OutOfRange_IsIdempotent() public {
        token0.mint(address(hook), 5e18);
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));

        hook.rebalance(key);
        uint256 vaultAssets = vault.totalAssets();

        // Second rebalance when already in vault — no additional routing
        hook.rebalance(key);
        assertEq(vault.totalAssets(), vaultAssets, "Second rebalance must be idempotent");
    }

    function test_Route_DoubleRecall_Safe() public {
        token0.mint(address(hook), 5e18);
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);
        hook.rebalance(key); // recalls — capitalInVault = false

        hook.rebalance(key); // second recall attempt — safe no-op
        assertFalse(hook.getPoolState(poolId).capitalInVault);
    }

    function test_Route_RecallWithNoYield_YieldPoolsStayZero() public {
        token0.mint(address(hook), 5e18);
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        // Immediately recall without any time/yield
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);
        hook.rebalance(key);

        (,, uint256 vaultYield, uint256 boost) = hook.getTrancheAccounting(key);
        assertEq(vaultYield, 0, "No yield without time");
        assertEq(boost, 0, "No boost without yield");
    }

    // ── Liquidity — edge cases ────────────────────────────────────────────────

    function test_Liquidity_PartialRemoval_RemainingSharesCorrect() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _removeLiquidity(seniorLP, 4e18, true);
        assertEq(hook.seniorShareTokens(poolId).balanceOf(seniorLP), 6e18);
    }

    function test_Liquidity_TwoSeniors_IndependentBalances() public {
        address s2 = makeAddr("s2");
        _fundAndApprove(s2, 100_000e18);
        _addSeniorLiquidity(seniorLP, 7e18);
        _addSeniorLiquidity(s2, 3e18);

        assertEq(hook.seniorShareTokens(poolId).balanceOf(seniorLP), 7e18);
        assertEq(hook.seniorShareTokens(poolId).balanceOf(s2), 3e18);
        assertEq(hook.seniorShareTokens(poolId).totalSupply(), 10e18);
    }

    function test_Liquidity_TwoJuniors_IndependentBalances() public {
        address j2 = makeAddr("j2");
        _fundAndApprove(j2, 100_000e18);
        _addJuniorLiquidity(juniorLP, 4e18);
        _addJuniorLiquidity(j2, 6e18);

        assertEq(hook.juniorShareTokens(poolId).balanceOf(juniorLP), 4e18);
        assertEq(hook.juniorShareTokens(poolId).balanceOf(j2), 6e18);
    }

    function test_Liquidity_RemoveAll_TotalSupplyZero() public {
        _addSeniorLiquidity(seniorLP, 5e18);
        _removeLiquidity(seniorLP, 5e18, true);
        assertEq(hook.seniorShareTokens(poolId).totalSupply(), 0);
    }

    function test_Liquidity_ReDepositAfterFullWithdrawal_Works() public {
        _addSeniorLiquidity(seniorLP, 5e18);
        _removeLiquidity(seniorLP, 5e18, true);
        _addSeniorLiquidity(seniorLP, 3e18);
        assertEq(hook.seniorShareTokens(poolId).balanceOf(seniorLP), 3e18);
    }

    function test_Liquidity_SmallestPossibleDelta_MintedCorrectly() public {
        _addSeniorLiquidity(seniorLP, 1); // 1 wei
        assertEq(hook.seniorShareTokens(poolId).balanceOf(seniorLP), 1);
    }

    // ── Hook callbacks — direct call security ────────────────────────────────

    function test_DirectCall_BeforeAddLiquidity_Reverts() public {
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1e18, salt: bytes32(0)
        });
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, p, abi.encode(true, address(this)));
    }

    function test_DirectCall_AfterAddLiquidity_Reverts() public {
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1e18, salt: bytes32(0)
        });
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterAddLiquidity(
            address(this),
            key,
            p,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(true, address(this))
        );
    }

    function test_DirectCall_BeforeRemoveLiquidity_Reverts() public {
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -1e18, salt: bytes32(0)
        });
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(this), key, p, abi.encode(true, address(this)));
    }

    function test_DirectCall_AfterRemoveLiquidity_Reverts() public {
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -1e18, salt: bytes32(0)
        });
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterRemoveLiquidity(
            address(this),
            key,
            p,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(true, address(this))
        );
    }

    function test_DirectCall_AfterSwap_Reverts() public {
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(address(this), key, sp, BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    function test_DirectCall_AfterInitialize_Reverts() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    // ── Permissionless rebalance ──────────────────────────────────────────────

    function test_Rebalance_AnyoneCanCall_NoRevert() public {
        vm.prank(makeAddr("randomCaller"));
        hook.rebalance(key); // in range → no-op; must not revert
    }

    // ── Pending yield edge cases ──────────────────────────────────────────────

    function test_PendingSenior_BeforeAnySwaps_IsZero() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        assertEq(hook.pendingSeniorYield(key, seniorLP), 0);
    }

    function test_PendingJunior_BeforeAnySwaps_IsZero() public {
        _addJuniorLiquidity(juniorLP, 10e18);
        assertEq(hook.pendingJuniorYield(key, juniorLP), 0);
    }

    function test_PendingSenior_AfterSwap_Positive() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _swap(swapper, true, -1e14);
        assertGt(hook.pendingSeniorYield(key, seniorLP), 0);
    }

    function test_PendingJunior_AfterSwap_Positive() public {
        _addJuniorLiquidity(juniorLP, 10e18);
        _swap(swapper, true, -1e14);
        assertGt(hook.pendingJuniorYield(key, juniorLP), 0);
    }

    function test_PendingYield_UnknownAddress_IsZero() public {
        assertEq(hook.pendingSeniorYield(key, makeAddr("nobody")), 0);
        assertEq(hook.pendingJuniorYield(key, makeAddr("nobody")), 0);
    }

    // ── Fee accumulation direction invariant ─────────────────────────────────

    function test_FeePool_MonotonicallyNonDecreasing_Senior() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);
        uint256 prev;
        for (uint256 i = 0; i < 6; i++) {
            _swap(swapper, i % 2 == 0, -1e14);
            (uint256 sf,,,) = hook.getTrancheAccounting(key);
            assertGe(sf, prev, "Senior fee pool must not decrease");
            prev = sf;
        }
    }

    function test_FeePool_MonotonicallyNonDecreasing_Junior() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);
        uint256 prev;
        for (uint256 i = 0; i < 6; i++) {
            _swap(swapper, i % 2 == 0, -1e14);
            (, uint256 jf,,) = hook.getTrancheAccounting(key);
            assertGe(jf, prev, "Junior fee pool must not decrease");
            prev = jf;
        }
    }
}
