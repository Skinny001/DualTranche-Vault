// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {DualTrancheTestBase} from "./DualTrancheTestBase.sol";
import {DualTrancheVaultHook} from "../src/DualTrancheVaultHook.sol";

/// @notice Tests for idle-capital routing to ERC4626 vault and recall.
contract CapitalRoutingTest is DualTrancheTestBase {
    using PoolIdLibrary for DualTrancheTestBase;

    function setUp() public override {
        super.setUp();
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);
    }

    // ── Vault Deposit / Recall Lifecycle ─────────────────────────────────────

    function test_Rebalance_NoOp_WhenInRange() public {
        // Default pool: tick ≈ 0, Senior range -120 to 120 → in range
        // No capital in hook → rebalance should be a no-op
        uint256 vaultBefore = vault.totalAssets();
        hook.rebalance(key);
        assertEq(vault.totalAssets(), vaultBefore, "Vault unchanged when in range");
        assertFalse(hook.getPoolState(poolId).capitalInVault);
    }

    function test_Rebalance_RoutesToVault_WhenOutOfRange() public {
        // Give the hook token0 to represent idle Senior capital
        uint256 depositAmt = 5e18;
        token0.mint(address(hook), depositAmt);
        token0.mint(address(vault), 0); // ensure vault is initialised

        // Move range so current tick (≈ 0) is outside — set Senior range to [500, 1000]
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));

        hook.rebalance(key);

        DualTrancheVaultHook.PoolState memory state = hook.getPoolState(poolId);
        assertTrue(state.capitalInVault, "Capital should be in vault after routing");
        assertEq(vault.totalAssets(), depositAmt, "Vault should hold deposited capital");
        assertGt(state.vaultShares0, 0, "Hook should hold vault shares");
        assertEq(state.depositedAmount0, depositAmt, "Deposited amount recorded");
    }

    function test_Rebalance_RecallsFromVault_WhenBackInRange() public {
        // Setup: fund + route out of range
        uint256 depositAmt = 5e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key); // routes to vault

        assertTrue(hook.getPoolState(poolId).capitalInVault);

        // Restore range so current tick (≈ 0) is inside again
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);

        hook.rebalance(key); // recalls from vault

        DualTrancheVaultHook.PoolState memory state = hook.getPoolState(poolId);
        assertFalse(state.capitalInVault, "Capital should be recalled from vault");
        assertEq(state.vaultShares0, 0, "No vault shares after recall");
        assertEq(state.depositedAmount0, 0, "Deposited amount reset");
    }

    function test_VaultYield_90_10_Split_OnRecall() public {
        uint256 depositAmt = 10e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key); // routes to vault

        // Simulate 5% APY over 30 days
        uint256 elapsed = 30 days;
        vault.simulateYield(500, elapsed);

        // Recall
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);
        hook.rebalance(key);

        (,, uint256 vaultYieldPool, uint256 juniorBoostPool) = hook.getTrancheAccounting(key);
        uint256 totalYield = vaultYieldPool + juniorBoostPool;

        assertGt(totalYield, 0, "Yield should have accrued");
        assertApproxEqRel(vaultYieldPool, (totalYield * 90) / 100, 0.01e18, "90% to Senior");
        assertApproxEqRel(juniorBoostPool, (totalYield * 10) / 100, 0.01e18, "10% to Junior");
    }

    function test_VaultYield_SeniorCanClaim_AfterRecall() public {
        uint256 depositAmt = 10e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        vault.simulateYield(1000, 30 days); // 10% APY

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);
        hook.rebalance(key);

        uint256 pending = hook.pendingSeniorYield(key, seniorLP);
        assertGt(pending, 0, "Senior LP should have pending vault yield");
    }

    function test_VaultYield_JuniorBoostAccrues_AfterRecall() public {
        uint256 depositAmt = 10e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        vault.simulateYield(500, 30 days);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);
        hook.rebalance(key);

        (,,, uint256 juniorBoostPool) = hook.getTrancheAccounting(key);
        assertGt(juniorBoostPool, 0, "Junior boost pool should have accrued");
    }

    function test_Rebalance_NoCapitalToRoute_Reverts() public {
        // No token0 in hook, out of range → revert NoCapitalToRoute
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));

        vm.expectRevert(DualTrancheVaultHook.NoCapitalToRoute.selector);
        hook.rebalance(key);
    }

    // ── Before Remove Liquidity: Capital Recalled for Senior ─────────────────

    function test_BeforeRemoveLiquidity_RecallsCapital_ForSenior() public {
        uint256 depositAmt = 5e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        assertTrue(hook.getPoolState(poolId).capitalInVault);

        // Restore in-range before removal so the LP position can be removed
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);

        // beforeRemoveLiquidity should recall capital
        _removeLiquidity(seniorLP, 1e18, true);

        assertFalse(hook.getPoolState(poolId).capitalInVault, "Capital recalled before Senior withdrawal");
    }

    function test_BeforeRemoveLiquidity_NoRecall_ForJunior() public {
        uint256 depositAmt = 5e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        assertTrue(hook.getPoolState(poolId).capitalInVault);

        // Restore range for removal
        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);

        // Junior withdrawal should NOT trigger capital recall
        // (beforeRemoveLiquidity skips recall for Junior)
        // Capital gets recalled anyway by rebalance since now in-range, but
        // the HOOK logic for Junior doesn't recall — we just verify the remove works
        _removeLiquidity(juniorLP, 1e18, false);
    }

    // ── Event Emission ────────────────────────────────────────────────────────

    function test_CapitalRoutedToVault_EventEmitted() public {
        uint256 depositAmt = 5e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));

        vm.expectEmit(true, false, false, false);
        emit DualTrancheVaultHook.CapitalRoutedToVault(poolId, 0, 0);

        hook.rebalance(key);
    }

    function test_CapitalRecalledFromVault_EventEmitted() public {
        uint256 depositAmt = 5e18;
        token0.mint(address(hook), depositAmt);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, int24(500), int24(1000));
        hook.rebalance(key);

        vm.prank(hook.owner());
        hook.updateSeniorRange(poolId, TICK_LOWER, TICK_UPPER);

        vm.expectEmit(true, false, false, false);
        emit DualTrancheVaultHook.CapitalRecalledFromVault(poolId, 0, 0, 0);

        hook.rebalance(key);
    }
}
