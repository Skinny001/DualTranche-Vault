// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

/// @notice ERC20 share token for the Senior (StableLP) tranche.
/// @dev Only the DualTrancheVaultHook can mint or burn shares.
contract SeniorShares is ERC20 {
    address public immutable hook;

    error NotHook();

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    constructor(address _hook, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        hook = _hook;
    }

    function mint(address to, uint256 amount) external onlyHook {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyHook {
        _burn(from, amount);
    }
}
