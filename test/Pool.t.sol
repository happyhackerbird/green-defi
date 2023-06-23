// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

// import "forge-std/contracts/test/Test.sol";
import {DSTest} from "ds-test/test.sol";
import {console} from "./utils/Console.sol";
import {LendingPool} from "contracts/protocol/Pool/LendingPool.sol";

contract PoolTest is DSTest {
    LendingPool pool;

    function setUp() public {
        pool = new LendingPool();
    }

    function test_getAddressProvider() public {
        console.log(
            "address provider: %s",
            (pool.getAddressesProvider().getAddress(0))
        );
    }
}
