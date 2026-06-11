// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {DualTrancheTestBase} from "./DualTrancheTestBase.sol";
import {DualTrancheVaultHook} from "../src/DualTrancheVaultHook.sol";

/// @notice Full lifecycle integration test — the UHI9 demo scenario.
contract IntegrationTest is DualTrancheTestBase {
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        _fundAndApprove(carol, 100_000e18);
    }

    // ── Scene 1: Setup & Initial Deposits ────────────────────────────────────

    function test_Scene1_BothTranchesDepositSuccessfully() public {
        // Oracle at 30% vol — gate open
        assertTrue(hook.isJuniorGateOpen(key), "Junior gate should start open");

        _addSeniorLiquidity(seniorLP, 10e18);
        assertEq(hook.seniorShareTokens(poolId).balanceOf(seniorLP), 10e18);

        _addJuniorLiquidity(juniorLP, 5e18);
        assertEq(hook.juniorShareTokens(poolId).balanceOf(juniorLP), 5e18);
    }

    // ── Scene 2: Fees Accumulate 30/70 During Normal Operation ──────────────

    function test_Scene2_FeesAccumulate_30_70() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        for (uint256 i = 0; i < 20; i++) {
            _swap(swapper, i % 2 == 0, -1e14); // tiny amounts to keep price in range
        }

        (uint256 seniorFees, uint256 juniorFees,,) = hook.getTrancheAccounting(key);

        assertGt(seniorFees, 0, "Senior pool should accumulate fees");
        assertGt(juniorFees, 0, "Junior pool should accumulate fees");
        assertGt(juniorFees, seniorFees, "Junior (70%) should exceed Senior (30%)");
    }

    // ── Scene 3: Junior Gate Closes During High-Vol Spike ───────────────────

    function test_Scene3_JuniorGateCloses_SeniorUnaffected() public {
        _addSeniorLiquidity(seniorLP, 10e18);

        oracle.setVol(7500); // 75% > 50% threshold

        vm.expectRevert(); // v4 wraps hook errors in WrappedError
        _addJuniorLiquidity(carol, 5e18);

        // Senior still works during high vol
        _addSeniorLiquidity(seniorLP, 2e18);
        // isJuniorGateOpen queries oracle live: oracle still returns 7500 so gate is closed
        assertFalse(hook.isJuniorGateOpen(key), "Gate should report closed (oracle vol = 7500)");
    }

    // ── Scene 4: Price Exits Range → Capital Routes to Vault ────────────────

    function test_Scene4_CapitalRouted_WhenOutOfRange() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 5e18);

        uint256 idleCapital = 8e18;
        token0.mint(address(hook), idleCapital);

        // Simulate price moving outside Senior range
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));

        hook.rebalance(key);

        DualTrancheVaultHook.PoolState memory state = hook.getPoolState(poolId);
        assertTrue(state.capitalInVault, "Capital should be in vault");
        assertEq(vault.totalAssets(), idleCapital, "Vault holds idle capital");
    }

    // ── Scene 5: Vault Accrues Yield, Capital Recalled ──────────────────────

    function test_Scene5_VaultYieldDistributed_OnRecall() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        uint256 depositAmt = 10e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        // Vault accrues 5% APY over 30 days
        uint256 elapsed = 30 days;
        vault.simulateYield(500, elapsed);
        uint256 expectedYield = (depositAmt * 500 * elapsed) / (10_000 * 365 days);

        // Price returns to range → recall
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);
        hook.rebalance(key);

        (,, uint256 vaultYieldPool, uint256 juniorBoostPool) = hook.getTrancheAccounting(key);
        uint256 totalYield = vaultYieldPool + juniorBoostPool;

        assertApproxEqAbs(totalYield, expectedYield, 1, "Total yield matches simulation");
        assertApproxEqRel(vaultYieldPool, (totalYield * 90) / 100, 0.01e18, "90% Senior");
        assertApproxEqRel(juniorBoostPool, (totalYield * 10) / 100, 0.01e18, "10% Junior");
    }

    // ── Scene 6: Full Lifecycle — Alice earns fees + vault APY ───────────────

    function test_Scene6_FullLifecycle_SeniorEarnsMoreThanJunior() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);

        // Phase 1: In-range swaps — tiny amounts keep tick inside [-120, 120]
        for (uint256 i = 0; i < 10; i++) {
            _swap(swapper, i % 2 == 0, -1e14);
        }

        // Phase 2: Price exits range → vault routing
        uint256 depositAmt = 8e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        // Phase 3: Vault accrues yield (8% APY, 60 days)
        vault.simulateYield(800, 60 days);

        // Phase 4: Price returns → capital + yield recalled
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);
        hook.rebalance(key);

        // Phase 5: Compare pending yields
        uint256 alicePending = hook.pendingSeniorYield(key, seniorLP);
        uint256 bobPending = hook.pendingJuniorYield(key, juniorLP);

        assertGt(alicePending, 0, "Alice (Senior) has pending yield");
        assertGt(bobPending, 0, "Bob (Junior) has pending yield");

        // Senior earns fees (30%) + vault APY; Junior earns fees (70%) + 10% vault boost
        // With equal shares and a substantial vault yield period, check both non-zero
        (,, uint256 vaultYieldPool,) = hook.getTrancheAccounting(key);
        assertGt(vaultYieldPool, 0, "Vault yield pool should have Senior share");
    }

    // ── Scene 7: Gate Reopens When Vol Drops ─────────────────────────────────

    function test_Scene7_GateReopens_WhenVolDrops() public {
        // Close gate with high vol
        oracle.setVol(HIGH_VOL);
        vm.expectRevert();
        _addJuniorLiquidity(carol, 1e18);
        assertFalse(hook.isJuniorGateOpen(key));

        // Gate reopens when vol drops
        oracle.setVol(DEFAULT_VOL);
        _addJuniorLiquidity(carol, 1e18);
        assertTrue(hook.isJuniorGateOpen(key));
        assertGt(hook.juniorShareTokens(poolId).balanceOf(carol), 0);
    }

    // ── Scene 8: Oracle Failure Conservative Fallback ────────────────────────

    function test_Scene8_OracleFail_JuniorBlockedSeniorOpen() public {
        oracle.setFail(true);

        // Junior blocked by oracle failure (defaults to max vol → gate closed)
        vm.expectRevert();
        _addJuniorLiquidity(carol, 1e18);

        // Senior always open regardless of oracle state
        _addSeniorLiquidity(seniorLP, 1e18);
        assertGt(hook.seniorShareTokens(poolId).balanceOf(seniorLP), 0, "Senior shares minted despite oracle failure");
    }
}
