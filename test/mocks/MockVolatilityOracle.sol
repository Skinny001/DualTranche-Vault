// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVolatilityOracle} from "../../src/interfaces/IVolatilityOracle.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Configurable vol oracle for testing.
contract MockVolatilityOracle is IVolatilityOracle {
    uint256 private _vol;
    bool private _shouldFail;

    constructor(uint256 initialVol) {
        _vol = initialVol;
    }

    function setVol(uint256 vol) external {
        _vol = vol;
        _shouldFail = false;
    }

    function setFail(bool fail) external {
        _shouldFail = fail;
    }

    function getAnnualizedVol(Currency, Currency) external view override returns (uint256) {
        require(!_shouldFail, "MockOracle: intentional failure");
        return _vol;
    }
}
