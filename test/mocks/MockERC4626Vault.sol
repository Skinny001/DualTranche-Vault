// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal ERC4626 vault with yield simulation for testing.
contract MockERC4626Vault is ERC4626 {
    constructor(address asset_) ERC4626(IERC20(asset_)) ERC20("Mock Vault Share", "mvSHARE") {}

    /// @notice Simulates yield accrual by minting additional underlying to the vault.
    /// @param annualBps   Annual yield in bps (e.g. 500 = 5%).
    /// @param elapsed     Seconds elapsed since last accrual.
    function simulateYield(uint256 annualBps, uint256 elapsed) external {
        uint256 assets = totalAssets();
        if (assets == 0) return;
        uint256 yieldAmount = (assets * annualBps * elapsed) / (10_000 * 365 days);
        if (yieldAmount == 0) return;
        MockERC20(asset()).mint(address(this), yieldAmount);
    }
}
