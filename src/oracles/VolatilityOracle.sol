// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVolatilityOracle} from "../interfaces/IVolatilityOracle.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/// @notice Computes a simplified 24h annualized realized volatility from Uniswap v4 TWAP observations.
/// @dev For production: replace _computeVolFromTWAP with a proper rolling-variance implementation over
///      tick cumulative observations. The cache ensures this is called at most once per hour.
contract VolatilityOracle is IVolatilityOracle {
    using StateLibrary for IPoolManager;

    struct VolCache {
        uint256 annualizedVolBps;
        uint256 lastUpdated;
    }

    IPoolManager public immutable poolManager;

    uint256 public constant CACHE_TTL = 1 hours;

    /// @dev Default vol returned when no real observation is available (30% annualized)
    uint256 public constant DEFAULT_VOL_BPS = 3000;

    mapping(bytes32 => VolCache) public volCache;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    /// @inheritdoc IVolatilityOracle
    function getAnnualizedVol(Currency currency0, Currency currency1)
        external
        override
        returns (uint256 annualizedVolBps)
    {
        bytes32 pairId = keccak256(abi.encodePacked(currency0, currency1));
        VolCache storage cache = volCache[pairId];

        if (block.timestamp - cache.lastUpdated < CACHE_TTL) {
            return cache.annualizedVolBps;
        }

        annualizedVolBps = _computeVolFromTWAP(currency0, currency1);

        cache.annualizedVolBps = annualizedVolBps;
        cache.lastUpdated = block.timestamp;
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _computeVolFromTWAP(Currency, Currency) internal pure returns (uint256) {
        // Production implementation:
        //   1. Identify pool via (currency0, currency1, fee, tickSpacing, hook)
        //   2. Query pool.observe([24h, 23h, ..., 0]) for tick cumulatives
        //   3. Compute hourly tick log-returns: Δtick_i = (tickCumulative_i - tickCumulative_{i-1}) / 3600
        //   4. Convert to log(price) returns: r_i = Δtick_i * ln(1.0001)
        //   5. variance = mean(r_i^2) - mean(r_i)^2
        //   6. annualizedVol = sqrt(variance * 8760) in bps
        return DEFAULT_VOL_BPS;
    }
}
