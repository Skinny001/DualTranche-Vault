// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

interface IVolatilityOracle {
    /// @notice Returns the 24h annualized realized volatility for a currency pair in basis points.
    /// @dev e.g. 5000 = 50% annualized vol. Returns type(uint256).max on oracle failure.
    function getAnnualizedVol(Currency currency0, Currency currency1) external returns (uint256 annualizedVolBps);
}
