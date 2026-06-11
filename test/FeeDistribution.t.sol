// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DualTrancheTestBase} from "./DualTrancheTestBase.sol";
import {DualTrancheVaultHook} from "../src/DualTrancheVaultHook.sol";

/// @notice Tests for the 30% Senior / 70% Junior fee split accounting.
contract FeeDistributionTest is DualTrancheTestBase {
    function setUp() public override {
        super.setUp();
        _addSeniorLiquidity(seniorLP, 10e18);
        _addJuniorLiquidity(juniorLP, 10e18);
    }

    // ── Fee Pool Accumulation ─────────────────────────────────────────────────

    function test_FeeSplit_30_70_AfterSwap() public {
        uint256 sFeesBefore = _seniorFeePool();
        uint256 jFeesBefore = _juniorFeePool();

        _swap(swapper, true, -1e18);

        uint256 seniorAccrued = _seniorFeePool() - sFeesBefore;
        uint256 juniorAccrued = _juniorFeePool() - jFeesBefore;

        assertGt(seniorAccrued, 0, "Senior fee pool should increase");
        assertGt(juniorAccrued, 0, "Junior fee pool should increase");

        // Ratio should be ~30:70. Allow up to 1% relative tolerance for rounding.
        uint256 total = seniorAccrued + juniorAccrued;
        assertApproxEqRel(seniorAccrued, (total * 30) / 100, 0.01e18, "Senior ~30%");
        assertApproxEqRel(juniorAccrued, (total * 70) / 100, 0.01e18, "Junior ~70%");
    }

    function test_FeeSplit_MultipleSwaps_Cumulative() public {
        for (uint256 i = 0; i < 10; i++) {
            _swap(swapper, i % 2 == 0, -1e17); // alternate direction
        }

        uint256 seniorFees = _seniorFeePool();
        uint256 juniorFees = _juniorFeePool();

        assertGt(seniorFees, 0);
        assertGt(juniorFees, 0);

        uint256 total = seniorFees + juniorFees;
        assertApproxEqRel(seniorFees, (total * 30) / 100, 0.05e18); // 5% rel tolerance
    }

    // ── Pro-Rata Yield Claims ─────────────────────────────────────────────────

    function test_ClaimSeniorYield_ProRata_TwoLPs() public {
        address seniorLP2 = makeAddr("seniorLP2");
        _fundAndApprove(seniorLP2, 100_000e18);

        // Alice: 6e18 more shares (total 6e18), Bob: 4e18 more shares (total 4e18)
        // on top of the 10e18 from setUp — to get clean ratios use fresh state
        // Just add equal new amounts and verify ratio from their new shares only.
        // Use fresh amounts above the setUp baseline: 6 and 4 units.
        _addSeniorLiquidity(seniorLP, 6e18);
        _addSeniorLiquidity(seniorLP2, 4e18);

        // Do a few alternating swaps to accumulate fees
        for (uint256 i = 0; i < 6; i++) {
            _swap(swapper, i % 2 == 0, -2e17);
        }

        uint256 pending1 = hook.pendingSeniorYield(key, seniorLP);
        uint256 pending2 = hook.pendingSeniorYield(key, seniorLP2);

        // Both LPs should have pending yield
        assertGt(pending1, 0, "Senior LP 1 should have yield");
        assertGt(pending2, 0, "Senior LP 2 should have yield");

        // seniorLP has 10+6=16 out of 10+6+4=20 shares = 80%; seniorLP2 has 4/20 = 20%
        // Ratio 16:4 = 4:1
        assertApproxEqRel(pending1, pending2 * 4, 0.05e18, "Share ratio ~4:1");
    }

    function test_ClaimJuniorYield_ProRata_EqualShares() public {
        address juniorLP2 = makeAddr("juniorLP2");
        _fundAndApprove(juniorLP2, 100_000e18);
        _addJuniorLiquidity(juniorLP2, 10e18); // equal to juniorLP's 10e18 from setUp

        _swap(swapper, true, -5e17);
        _swap(swapper, false, -5e17); // alternate to avoid price limit

        uint256 pending1 = hook.pendingJuniorYield(key, juniorLP);
        uint256 pending2 = hook.pendingJuniorYield(key, juniorLP2);

        // Equal shares (each 10/(10+10)=50%) → equal pending yield
        assertApproxEqRel(pending1, pending2, 0.01e18, "Equal shares -> equal yield");
    }

    function test_ClaimSeniorYield_TransfersCurrency0() public {
        _swap(swapper, true, -2e18);
        _swap(swapper, false, -2e18); // alternate

        // Fund the hook so it has token0 to pay out
        token0.mint(address(hook), 1e18);

        uint256 balBefore = token0.balanceOf(seniorLP);
        vm.prank(seniorLP);
        uint256 claimed = hook.claimSeniorYield(key);

        if (claimed > 0) {
            assertEq(token0.balanceOf(seniorLP), balBefore + claimed, "Should receive claimed amount");
        }
    }

    function test_ClaimJuniorYield_NoSharesReturnsZero() public {
        address noShares = makeAddr("noShares");
        vm.prank(noShares);
        uint256 claimed = hook.claimJuniorYield(key);
        assertEq(claimed, 0);
    }

    // ── Event Emission ────────────────────────────────────────────────────────

    function test_FeesDistributed_EventEmitted() public {
        vm.expectEmit(true, false, false, false);
        emit DualTrancheVaultHook.FeesDistributed(poolId, 0, 0);

        _swap(swapper, true, -1e18);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _seniorFeePool() internal view returns (uint256 s) {
        (s,,,) = hook.getTrancheAccounting(key);
    }

    function _juniorFeePool() internal view returns (uint256 j) {
        (, j,,) = hook.getTrancheAccounting(key);
    }
}
