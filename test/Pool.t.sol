// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

// import "forge-std/contracts/test/Test.sol";
import {DSTest} from "ds-test/test.sol";
import "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {LendingPool} from "contracts/protocol/Pool/LendingPool.sol";
import {LendingPoolAddressesProviderRegistry} from "contracts/protocol/configuration/LendingPoolAddressesProviderRegistry.sol";
import {LendingPoolAddressesProvider} from "contracts/protocol/configuration/LendingPoolAddressProvider.sol";
import {AToken} from "contracts/protocol/tokenization/AToken.sol";
import {StableDebtToken} from "contracts/protocol/tokenization/StableDebtToken.sol";

contract PoolTest is DSTest {
    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    LendingPool implementation;
    LendingPool pool;
    LendingPoolAddressesProviderRegistry registry;
    LendingPoolAddressesProvider polygonProvider;
    AToken aToken;
    StableDebtToken stableDebtToken;
    address admin = address(1234);

    address asset = address(0xD838290e877E0188a4A44700463419ED96c16107);

    function setUp() public {
        vm.startPrank(admin);
        implementation = new LendingPool();
        registry = new LendingPoolAddressesProviderRegistry();
        //get the Polygon market & register with the registry
        polygonProvider = new LendingPoolAddressesProvider("Polygon");
        registry.registerAddressesProvider(address(polygonProvider), 1);

        //create a proxy & set the address provider in the proxy to the polygonProvider
        polygonProvider.setLendingPoolImpl(address(implementation));
        //get the proxy
        pool = LendingPool(polygonProvider.getLendingPool());
        aToken = new AToken(
            pool,
            asset,
            address(0),
            "carbonA",
            "CA",
            address(0)
        );
        stableDebtToken = new StableDebtToken(
            address(pool),
            asset,
            "StabelDebt",
            "SD",
            address(0)
        );

        vm.stopPrank();
    }

    function initCarbonReserve() public {
        pool.initReserve(
            asset,
            address(aToken),
            address(stableDebtToken),
            address(0),
            address(0)
        );
    }

    function test_initReserve() public {
        initCarbonReserve();
    }

    function test_getAddressProvider() public {
        //test that pool proxy is correctly initialized with the provider address
        assertEq(
            address(pool),
            (pool.getAddressesProvider().getAddress(bytes32("LENDING_POOL")))
        );
    }

    function test_registeredAddress() public {
        assertEq(
            registry.getAddressesProviderIdByAddress(address(polygonProvider)),
            1
        );
    }

    function test_deposit() public {
        vm.deal(asset, 100);
        initCarbonReserve();
        pool.deposit(asset, 100, address(this), 0);
        // console.log(pool.getReserveData(address(1246)).aTokenAddress);
    }
}
