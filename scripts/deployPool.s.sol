// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "test/utils/Console.sol";
import {LendingPool} from "contracts/protocol/Pool/LendingPool.sol";

contract DeployPool is Script {
    LendingPool pool;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("POLYGON_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        pool = new LendingPool();
        console.log("LendingPool deployed at: %s", address(pool));
        vm.endBroadcast();
        // deploy LendingPool
        // deploy LendingPoolAddressesProvider
        // deploy LendingPoolConfigurator
        // deploy LendingPoolCollateralManager
        // deploy LendingPoolDataProvider
        // deploy LendingPoolLiquidationManager
        // deploy LendingPoolParamete
    }
}
