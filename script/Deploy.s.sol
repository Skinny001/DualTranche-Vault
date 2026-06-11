// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {DualTrancheVaultHook} from "../src/DualTrancheVaultHook.sol";
import {VolatilityOracle} from "../src/oracles/VolatilityOracle.sol";

/// @notice Deployment script for DualTrancheVaultHook.
///
/// Prerequisites:
///   1. Set POOL_MANAGER, TOKEN0, TOKEN1, VAULT env vars
///   2. Ensure the hook is deployed at an address matching the required flags
///      (see Step 6 in the build guide for address mining)
///
/// Steps:
///   forge script script/Deploy.s.sol:DeployOracle  --rpc-url $RPC --broadcast
///   forge script script/Deploy.s.sol:DeployHook    --rpc-url $RPC --broadcast
///   forge script script/Deploy.s.sol:InitPool      --rpc-url $RPC --broadcast
contract DeployOracle is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");

        vm.startBroadcast();
        VolatilityOracle oracle = new VolatilityOracle(poolManager);
        vm.stopBroadcast();

        console2.log("VolatilityOracle deployed at:", address(oracle));
    }
}

contract DeployHook is Script {
    // Required hook address flags
    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address oracle = vm.envAddress("ORACLE");
        address vault = vm.envAddress("VAULT");

        vm.startBroadcast();

        DualTrancheVaultHook hook = new DualTrancheVaultHook(
            IPoolManager(poolManager),
            // solhint-disable-next-line no-undef
            VolatilityOracle(oracle)
        );

        // Validate hook address (must end with FLAGS bits set)
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());

        hook.approveVault(vault);

        vm.stopBroadcast();

        console2.log("DualTrancheVaultHook deployed at:", address(hook));
        console2.log("Required flag bits:               0x%x", FLAGS);
        console2.log("Actual address bits:              0x%x", uint160(address(hook)) & FLAGS);
        console2.log("Flags match:", (uint160(address(hook)) & FLAGS) == FLAGS);
    }
}

contract InitPool is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hook = vm.envAddress("HOOK");
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        address vault = vm.envAddress("VAULT");

        uint256 juniorVolThreshold = vm.envOr("JUNIOR_VOL_THRESHOLD", uint256(5000)); // 50%
        int24 tickLower = int24(vm.envOr("TICK_LOWER", int256(-120)));
        int24 tickUpper = int24(vm.envOr("TICK_UPPER", int256(120)));
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", int256(60)));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0); // price = 1

        vm.startBroadcast();

        IPoolManager(poolManager).initialize(key, sqrtPriceX96);
        DualTrancheVaultHook(hook).initPool(key, vault, juniorVolThreshold, tickLower, tickUpper);

        vm.stopBroadcast();

        console2.log("Pool initialised with hook:", hook);
        console2.log("Junior vol threshold (bps):", juniorVolThreshold);
    }
}
