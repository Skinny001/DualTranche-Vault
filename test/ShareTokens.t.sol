// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DualTrancheTestBase} from "./DualTrancheTestBase.sol";
import {DualTrancheVaultHook} from "../src/DualTrancheVaultHook.sol";
import {SeniorShares} from "../src/SeniorShares.sol";
import {JuniorShares} from "../src/JuniorShares.sol";

/// @notice Unit tests for SeniorShares and JuniorShares ERC20 contracts.
contract ShareTokensTest is DualTrancheTestBase {
    SeniorShares internal sToken;
    JuniorShares internal jToken;

    function setUp() public override {
        super.setUp();
        sToken = hook.seniorShareTokens(poolId);
        jToken = hook.juniorShareTokens(poolId);
    }

    // ── Metadata ──────────────────────────────────────────────────────────────

    function test_SeniorShares_NameContainsSenior() public {
        bytes memory name = bytes(sToken.name());
        assertTrue(name.length >= 6, "Name must be at least 6 chars");
        // Name is "Senior-<poolSym>"; check prefix bytes
        assertEq(name[0], bytes1("S"));
        assertEq(name[1], bytes1("e"));
        assertEq(name[2], bytes1("n"));
        assertEq(name[3], bytes1("i"));
        assertEq(name[4], bytes1("o"));
        assertEq(name[5], bytes1("r"));
    }

    function test_JuniorShares_NameContainsJunior() public {
        bytes memory name = bytes(jToken.name());
        assertTrue(name.length >= 6, "Name must be at least 6 chars");
        assertEq(name[0], bytes1("J"));
        assertEq(name[1], bytes1("u"));
        assertEq(name[2], bytes1("n"));
        assertEq(name[3], bytes1("i"));
        assertEq(name[4], bytes1("o"));
        assertEq(name[5], bytes1("r"));
    }

    function test_SeniorShares_SymbolContainsSLP() public {
        bytes memory sym = bytes(sToken.symbol());
        assertTrue(sym.length >= 3);
        assertEq(sym[0], bytes1("s"));
        assertEq(sym[1], bytes1("L"));
        assertEq(sym[2], bytes1("P"));
    }

    function test_JuniorShares_SymbolContainJLP() public {
        bytes memory sym = bytes(jToken.symbol());
        assertTrue(sym.length >= 3);
        assertEq(sym[0], bytes1("j"));
        assertEq(sym[1], bytes1("L"));
        assertEq(sym[2], bytes1("P"));
    }

    function test_SeniorShares_HookAddressCorrect() public {
        assertEq(sToken.hook(), address(hook));
    }

    function test_JuniorShares_HookAddressCorrect() public {
        assertEq(jToken.hook(), address(hook));
    }

    function test_SeniorShares_Decimals_18() public {
        assertEq(sToken.decimals(), 18);
    }

    function test_JuniorShares_Decimals_18() public {
        assertEq(jToken.decimals(), 18);
    }

    // ── Access control: mint / burn ───────────────────────────────────────────

    function test_SeniorShares_MintFromNonHook_Reverts() public {
        vm.prank(makeAddr("notHook"));
        vm.expectRevert(SeniorShares.NotHook.selector);
        sToken.mint(address(this), 1e18);
    }

    function test_JuniorShares_MintFromNonHook_Reverts() public {
        vm.prank(makeAddr("notHook"));
        vm.expectRevert(JuniorShares.NotHook.selector);
        jToken.mint(address(this), 1e18);
    }

    function test_SeniorShares_BurnFromNonHook_Reverts() public {
        _addSeniorLiquidity(seniorLP, 1e18); // mint via hook
        vm.prank(makeAddr("notHook"));
        vm.expectRevert(SeniorShares.NotHook.selector);
        sToken.burn(seniorLP, 1e18);
    }

    function test_JuniorShares_BurnFromNonHook_Reverts() public {
        _addJuniorLiquidity(juniorLP, 1e18);
        vm.prank(makeAddr("notHook"));
        vm.expectRevert(JuniorShares.NotHook.selector);
        jToken.burn(juniorLP, 1e18);
    }

    // ── ERC20 transfer ────────────────────────────────────────────────────────

    function test_SeniorShares_Transfer_UpdatesBalances() public {
        _addSeniorLiquidity(seniorLP, 4e18);
        address recipient = makeAddr("recipient");

        vm.prank(seniorLP);
        sToken.transfer(recipient, 1e18);

        assertEq(sToken.balanceOf(seniorLP), 3e18);
        assertEq(sToken.balanceOf(recipient), 1e18);
    }

    function test_JuniorShares_Transfer_UpdatesBalances() public {
        _addJuniorLiquidity(juniorLP, 4e18);
        address recipient = makeAddr("recipient");

        vm.prank(juniorLP);
        jToken.transfer(recipient, 2e18);

        assertEq(jToken.balanceOf(juniorLP), 2e18);
        assertEq(jToken.balanceOf(recipient), 2e18);
    }

    function test_SeniorShares_ApproveAndTransferFrom() public {
        _addSeniorLiquidity(seniorLP, 3e18);
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");

        vm.prank(seniorLP);
        sToken.approve(spender, 2e18);

        vm.prank(spender);
        sToken.transferFrom(seniorLP, recipient, 2e18);

        assertEq(sToken.balanceOf(recipient), 2e18);
        assertEq(sToken.allowance(seniorLP, spender), 0);
    }

    function test_JuniorShares_ApproveAndTransferFrom() public {
        _addJuniorLiquidity(juniorLP, 3e18);
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");

        vm.prank(juniorLP);
        jToken.approve(spender, 1e18);

        vm.prank(spender);
        jToken.transferFrom(juniorLP, recipient, 1e18);

        assertEq(jToken.balanceOf(recipient), 1e18);
    }

    // ── Total supply tracking ─────────────────────────────────────────────────

    function test_SeniorShares_TotalSupply_TracksMultipleDeposits() public {
        _addSeniorLiquidity(seniorLP, 5e18);
        address lp2 = makeAddr("lp2");
        _fundAndApprove(lp2, 100_000e18);
        _addSeniorLiquidity(lp2, 3e18);

        assertEq(sToken.totalSupply(), 8e18);
    }

    function test_JuniorShares_TotalSupply_TracksMultipleDeposits() public {
        _addJuniorLiquidity(juniorLP, 5e18);
        address lp2 = makeAddr("jlp2");
        _fundAndApprove(lp2, 100_000e18);
        _addJuniorLiquidity(lp2, 7e18);

        assertEq(jToken.totalSupply(), 12e18);
    }

    function test_SeniorShares_TotalSupply_DecreasesOnBurn() public {
        _addSeniorLiquidity(seniorLP, 10e18);
        assertEq(sToken.totalSupply(), 10e18);

        _removeLiquidity(seniorLP, 4e18, true);
        assertEq(sToken.totalSupply(), 6e18);
    }

    function test_SeniorShares_BalanceOf_ZeroForNonHolder() public {
        assertEq(sToken.balanceOf(makeAddr("nobody")), 0);
    }

    // ── Yield entitlement follows shares ─────────────────────────────────────

    function test_PendingYield_FollowsShareTransfer() public {
        // seniorLP deposits; accumulates some fee yield
        _addSeniorLiquidity(seniorLP, 10e18);
        _swap(swapper, true, -1e14);
        _swap(swapper, false, -1e14);

        // Before transfer: seniorLP holds pending yield
        uint256 pendingBefore = hook.pendingSeniorYield(key, seniorLP);
        assertGt(pendingBefore, 0);

        // Transfer ALL shares to recipient
        // Note: must read balance BEFORE vm.prank — the balanceOf external call
        // would otherwise consume the prank before transfer runs.
        address recipient = makeAddr("recipient");
        uint256 bal = sToken.balanceOf(seniorLP);
        vm.prank(seniorLP);
        sToken.transfer(recipient, bal);

        // More swaps — new yield accumulates
        _swap(swapper, true, -1e14);
        _swap(swapper, false, -1e14);

        // Recipient now holds shares → pending yield > 0
        uint256 recipientPending = hook.pendingSeniorYield(key, recipient);
        assertGt(recipientPending, 0, "Recipient should accrue yield after receiving shares");
    }
}
