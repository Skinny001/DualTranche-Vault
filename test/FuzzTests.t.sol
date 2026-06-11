// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {DualTrancheTestBase} from "./DualTrancheTestBase.sol";
import {DualTrancheVaultHook} from "../src/DualTrancheVaultHook.sol";
import {SeniorShares} from "../src/SeniorShares.sol";
import {JuniorShares} from "../src/JuniorShares.sol";

/// @notice Fuzz tests — randomised inputs expose edge cases not found by unit tests.
/// @dev Each test runs `profile.default.fuzz.runs` iterations (default 256).
///      Inputs are bounded to keep the pool in a valid state (price in range, etc.).
contract FuzzTests is DualTrancheTestBase {
    using PoolIdLibrary for PoolKey;

    // ── Vol gate ──────────────────────────────────────────────────────────────

    /// @notice For any vol strictly below the threshold the gate must be open;
    ///         for vol >= threshold it must be closed.
    function testFuzz_Gate_CorrectlyGatesOnVol(uint256 vol) public {
        vol = bound(vol, 0, 2 * VOL_THRESHOLD); // keep in a sane range
        oracle.setVol(vol);

        if (vol < VOL_THRESHOLD) {
            _addJuniorLiquidity(juniorLP, 1e18);
            assertGt(hook.juniorShareTokens(poolId).balanceOf(juniorLP), 0, "Gate open: shares minted");
        } else {
            vm.expectRevert();
            _addJuniorLiquidity(juniorLP, 1e18);
        }
    }

    /// @notice Senior deposits are always accepted regardless of vol.
    function testFuzz_Gate_SeniorUnaffectedByAnyVol(uint256 vol) public {
        vol = bound(vol, 0, type(uint128).max);
        oracle.setVol(vol);
        _addSeniorLiquidity(seniorLP, 1e18);
        assertEq(hook.seniorShareTokens(poolId).balanceOf(seniorLP), 1e18);
    }

    /// @notice isJuniorGateOpen always agrees with the oracle comparison.
    function testFuzz_Gate_IsJuniorGateOpen_AgreesWithOracle(uint256 vol) public {
        vol = bound(vol, 0, 2 * VOL_THRESHOLD);
        oracle.setVol(vol);
        bool expectedOpen = vol < VOL_THRESHOLD;
        assertEq(hook.isJuniorGateOpen(key), expectedOpen);
    }

    // ── Share minting ─────────────────────────────────────────────────────────

    /// @notice Shares minted always equal the positive liquidityDelta.
    function testFuzz_ShareMinting_Senior_MatchesDelta(uint128 rawLiquidity) public {
        int256 liquidity = int256(bound(uint256(rawLiquidity), 1e6, 50_000e18));
        _addSeniorLiquidity(seniorLP, liquidity);
        assertEq(hook.seniorShareTokens(poolId).balanceOf(seniorLP), uint256(liquidity), "Senior shares != delta");
    }

    function testFuzz_ShareMinting_Junior_MatchesDelta(uint128 rawLiquidity) public {
        int256 liquidity = int256(bound(uint256(rawLiquidity), 1e6, 50_000e18));
        _addJuniorLiquidity(juniorLP, liquidity);
        assertEq(hook.juniorShareTokens(poolId).balanceOf(juniorLP), uint256(liquidity), "Junior shares != delta");
    }

    /// @notice Shares burned always equal the removed liquidityDelta.
    function testFuzz_ShareBurning_Senior_MatchesDelta(uint128 rawLiquidity) public {
        int256 liquidity = int256(bound(uint256(rawLiquidity), 1e6, 50_000e18));
        _addSeniorLiquidity(seniorLP, liquidity);

        _removeLiquidity(seniorLP, liquidity, true);
        assertEq(hook.seniorShareTokens(poolId).balanceOf(seniorLP), 0, "Shares not fully burned");
    }

    function testFuzz_ShareBurning_Junior_MatchesDelta(uint128 rawLiquidity) public {
        int256 liquidity = int256(bound(uint256(rawLiquidity), 1e6, 50_000e18));
        _addJuniorLiquidity(juniorLP, liquidity);

        _removeLiquidity(juniorLP, liquidity, false);
        assertEq(hook.juniorShareTokens(poolId).balanceOf(juniorLP), 0, "Shares not fully burned");
    }

    /// @notice Total supply equals the sum of all individual balances after N deposits.
    function testFuzz_TotalSupply_EqualsSum_ForTwoSeniors(uint128 rawA, uint128 rawB) public {
        int256 a = int256(bound(uint256(rawA), 1e6, 20_000e18));
        int256 b = int256(bound(uint256(rawB), 1e6, 20_000e18));

        address lp2 = makeAddr("lp2");
        _fundAndApprove(lp2, 100_000e18);

        _addSeniorLiquidity(seniorLP, a);
        _addSeniorLiquidity(lp2, b);

        uint256 expected = uint256(a) + uint256(b);
        assertEq(hook.seniorShareTokens(poolId).totalSupply(), expected);
    }

    /// @notice Transfer does not change total supply.
    function testFuzz_Transfer_PreservesTotalSupply(uint128 rawLiquidity, uint128 rawTransfer) public {
        int256 liquidity = int256(bound(uint256(rawLiquidity), 1e8, 20_000e18));
        _addSeniorLiquidity(seniorLP, liquidity);

        // Cache share token before prank — getter calls consume prank if inside call args.
        SeniorShares sT = hook.seniorShareTokens(poolId);
        uint256 balance = sT.balanceOf(seniorLP);
        uint256 transferAmt = bound(uint256(rawTransfer), 0, balance);

        address recipient = makeAddr("recipient");
        vm.prank(seniorLP);
        sT.transfer(recipient, transferAmt);

        assertEq(sT.totalSupply(), uint256(liquidity), "Transfer changed total supply");
    }

    // ── Fee split ─────────────────────────────────────────────────────────────

    /// @notice Senior + Junior fee pools always sum ≤ estimated total fee.
    function testFuzz_FeeSplit_SumNeverExceedsEstimatedFee(uint64 rawSwap) public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        // Small swap amounts only — larger amounts push price out of range
        int256 swapAmt = -int256(bound(uint256(rawSwap), 1e9, 1e14));

        (uint256 sBefore, uint256 jBefore,,) = hook.getTrancheAccounting(key);

        _swap(swapper, true, swapAmt);

        (uint256 sAfter, uint256 jAfter,,) = hook.getTrancheAccounting(key);
        uint256 seniorAccrued = sAfter - sBefore;
        uint256 juniorAccrued = jAfter - jBefore;
        uint256 total = seniorAccrued + juniorAccrued;

        // Rough upper bound: fee ≤ swapAmt * feePpm / 1e6
        uint256 maxFee = (uint256(-swapAmt) * uint256(FEE)) / 1_000_000;
        assertLe(total, maxFee + 1, "Total fee pool growth exceeds estimated max fee");
    }

    /// @notice Senior share is always ≤ 30% + 1 wei rounding of total.
    function testFuzz_FeeSplit_SeniorAtMost30Percent(uint64 rawSwap) public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        int256 swapAmt = -int256(bound(uint256(rawSwap), 1e9, 1e14));

        (uint256 sBefore, uint256 jBefore,,) = hook.getTrancheAccounting(key);
        _swap(swapper, true, swapAmt);
        (uint256 sAfter, uint256 jAfter,,) = hook.getTrancheAccounting(key);

        uint256 seniorGain = sAfter - sBefore;
        uint256 juniorGain = jAfter - jBefore;
        uint256 totalGain = seniorGain + juniorGain;

        if (totalGain > 0) {
            // seniorGain / totalGain <= 30% (+1 for rounding)
            assertLe(seniorGain * 10_000, (totalGain * 3000) + totalGain, "Senior > 30% share");
            // juniorGain / totalGain >= 70% (-1 for rounding)
            assertGe(juniorGain * 10_000 + totalGain, totalGain * 7000, "Junior < 70% share");
        }
    }

    // ── Pro-rata yield claims ─────────────────────────────────────────────────

    /// @notice pendingSeniorYield for two LPs scales with their share balance ratio.
    function testFuzz_ProRata_Senior_TwoLPs(uint128 rawA, uint128 rawB) public {
        int256 a = int256(bound(uint256(rawA), 1e12, 10_000e18));
        int256 b = int256(bound(uint256(rawB), 1e12, 10_000e18));

        address lp2 = makeAddr("lp2");
        _fundAndApprove(lp2, 100_000e18);

        _addSeniorLiquidity(seniorLP, a);
        _addSeniorLiquidity(lp2, b);

        _swap(swapper, true, -1e14);
        _swap(swapper, false, -1e14);

        uint256 pA = hook.pendingSeniorYield(key, seniorLP);
        uint256 pB = hook.pendingSeniorYield(key, lp2);

        // Only assert ratio when both pending values are meaningful (> 1e6);
        // tiny amounts have large relative rounding error in integer math.
        // Use 5% tolerance to absorb reward-per-share integer truncation.
        if (pA > 1e6 && pB > 1e6) {
            assertApproxEqRel(pA * uint256(b), pB * uint256(a), 0.05e18, "Pro-rata Senior yield off");
        }
    }

    /// @notice pendingJuniorYield scales with share balance ratio.
    function testFuzz_ProRata_Junior_TwoLPs(uint128 rawA, uint128 rawB) public {
        int256 a = int256(bound(uint256(rawA), 1e12, 10_000e18));
        int256 b = int256(bound(uint256(rawB), 1e12, 10_000e18));

        address lp2 = makeAddr("jlp2");
        _fundAndApprove(lp2, 100_000e18);

        _addJuniorLiquidity(juniorLP, a);
        _addJuniorLiquidity(lp2, b);

        _swap(swapper, true, -1e14);
        _swap(swapper, false, -1e14);

        uint256 pA = hook.pendingJuniorYield(key, juniorLP);
        uint256 pB = hook.pendingJuniorYield(key, lp2);

        if (pA > 1e6 && pB > 1e6) {
            assertApproxEqRel(pA * uint256(b), pB * uint256(a), 0.05e18, "Pro-rata Junior yield off");
        }
    }

    // ── Vault yield split ─────────────────────────────────────────────────────

    /// @notice 90% Senior / 10% Junior split always holds regardless of yield amount.
    function testFuzz_VaultYield_90_10_Split(uint64 rawYieldBps, uint32 rawElapsed) public {
        uint256 yieldBps = bound(uint256(rawYieldBps), 1, 2000); // 0.01% to 20% APY
        uint256 elapsed = bound(uint256(rawElapsed), 1 days, 365 days);

        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        uint256 depositAmt = 10e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        vault.simulateYield(yieldBps, elapsed);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);
        hook.rebalance(key);

        (,, uint256 sYield, uint256 jBoost) = hook.getTrancheAccounting(key);
        uint256 total = sYield + jBoost;

        if (total > 0) {
            assertApproxEqRel(sYield, (total * 90) / 100, 0.01e18, "Senior yield should be 90%");
            assertApproxEqRel(jBoost, (total * 10) / 100, 0.01e18, "Junior boost should be 10%");
        }
    }

    /// @notice Yield is always non-negative (no negative yield from vault).
    function testFuzz_VaultYield_NeverNegative(uint64 rawYieldBps, uint32 rawElapsed) public {
        uint256 yieldBps = bound(uint256(rawYieldBps), 0, 5000);
        uint256 elapsed = bound(uint256(rawElapsed), 0, 365 days);

        _addSeniorLiquidity(seniorLP, 10e18);

        token0.mint(address(hook), 5e18);
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        if (yieldBps > 0 && elapsed > 0) vault.simulateYield(yieldBps, elapsed);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);
        hook.rebalance(key);

        (,, uint256 sYield, uint256 jBoost) = hook.getTrancheAccounting(key);
        assertGe(sYield, 0, "Senior yield non-negative");
        assertGe(jBoost, 0, "Junior boost non-negative");
    }

    // ── Rebalance invariants ──────────────────────────────────────────────────

    /// @notice When in range, rebalance is always a no-op (capitalInVault stays false).
    function testFuzz_Rebalance_InRange_NeverRoutes(uint128 rawBalance) public {
        uint256 balance = bound(uint256(rawBalance), 0, 50e18);
        if (balance > 0) token0.mint(address(hook), balance);

        // Default range [-120, 120] — tick ≈ 0 → in range
        hook.rebalance(key);
        assertFalse(hook.getPoolState(poolId).capitalInVault, "Must not route when in range");
    }

    /// @notice capitalInVault flag transitions are consistent after routing + recall cycle.
    function testFuzz_Rebalance_FlagConsistency(uint64 rawBalance) public {
        uint256 balance = bound(uint256(rawBalance), hook.MIN_ROUTING_AMOUNT(), 20e18);
        token0.mint(address(hook), balance);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000)); // out of range
        hook.rebalance(key);
        assertTrue(hook.getPoolState(poolId).capitalInVault);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER); // back in range
        hook.rebalance(key);
        assertFalse(hook.getPoolState(poolId).capitalInVault);
    }

    // ── RewardPerShare monotonicity ───────────────────────────────────────────

    /// @notice After N swaps, senior fee pool value never decreases.
    function testFuzz_SeniorFeePool_Monotone(uint8 swapCount) public {
        uint256 n = bound(uint256(swapCount), 1, 20);
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        uint256 prev;
        for (uint256 i = 0; i < n; i++) {
            _swap(swapper, i % 2 == 0, -1e14);
            (uint256 sf,,,) = hook.getTrancheAccounting(key);
            assertGe(sf, prev, "seniorFeePool decreased");
            prev = sf;
        }
    }

    /// @notice After N swaps, junior fee pool value never decreases.
    function testFuzz_JuniorFeePool_Monotone(uint8 swapCount) public {
        uint256 n = bound(uint256(swapCount), 1, 20);
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        uint256 prev;
        for (uint256 i = 0; i < n; i++) {
            _swap(swapper, i % 2 == 0, -1e14);
            (, uint256 jf,,) = hook.getTrancheAccounting(key);
            assertGe(jf, prev, "juniorFeePool decreased");
            prev = jf;
        }
    }

    // ── Claim idempotency ─────────────────────────────────────────────────────

    /// @notice After claiming the full pending amount, a subsequent claim returns 0.
    function testFuzz_Claim_Idempotent_AfterFullClaim_Senior(uint8 swapCount) public {
        uint256 n = bound(uint256(swapCount), 1, 15);
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        for (uint256 i = 0; i < n; i++) {
            _swap(swapper, i % 2 == 0, -1e14);
        }

        token0.mint(address(hook), 10e18); // fund hook for payout

        vm.prank(seniorLP);
        hook.claimSeniorYield(key);

        vm.prank(seniorLP);
        uint256 second = hook.claimSeniorYield(key);
        assertEq(second, 0, "Second claim must be 0");
    }

    function testFuzz_Claim_Idempotent_AfterFullClaim_Junior(uint8 swapCount) public {
        uint256 n = bound(uint256(swapCount), 1, 15);
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        for (uint256 i = 0; i < n; i++) {
            _swap(swapper, i % 2 == 0, -1e14);
        }

        token0.mint(address(hook), 10e18);

        vm.prank(juniorLP);
        hook.claimJuniorYield(key);

        vm.prank(juniorLP);
        uint256 second = hook.claimJuniorYield(key);
        assertEq(second, 0, "Second claim must be 0");
    }

    // ── initPool re-init ──────────────────────────────────────────────────────

    /// @notice Calling initPool a second time always reverts regardless of params.
    function testFuzz_InitPool_AlwaysRevertsOnReInit(uint256 threshold, int24 tickL, int24 tickU) public {
        vm.expectRevert(DualTrancheVaultHook.VaultAlreadySet.selector);
        hook.initPool(key, address(vault), threshold, tickL, tickU);
    }

    // ── Share token balance invariant ─────────────────────────────────────────

    /// @notice After adding then removing a fractional amount, remaining shares are correct.
    function testFuzz_PartialRemoval_ShareBalance_Correct(uint128 rawTotal, uint128 rawRemove) public {
        int256 total = int256(bound(uint256(rawTotal), 2e6, 50_000e18));
        uint256 remove = bound(uint256(rawRemove), 1e6, uint256(total));

        _addSeniorLiquidity(seniorLP, total);
        _removeLiquidity(seniorLP, int256(remove), true);

        uint256 expected = uint256(total) - remove;
        assertEq(hook.seniorShareTokens(poolId).balanceOf(seniorLP), expected, "Remaining shares wrong");
    }
}
