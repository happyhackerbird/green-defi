// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

// import "forge-std/contracts/test/Test.sol";
import {DSTest} from "ds-test/test.sol";
import "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {LendingPool} from "contracts/protocol/pool/LendingPool.sol";
import {LendingPoolAddressesProviderRegistry} from "contracts/protocol/configuration/LendingPoolAddressesProviderRegistry.sol";
import {LendingPoolAddressesProvider} from "contracts/protocol/configuration/LendingPoolAddressProvider.sol";
import {AToken} from "contracts/protocol/tokenization/AToken.sol";
import {StableDebtToken} from "contracts/protocol/tokenization/StableDebtToken.sol";
import {VariableDebtToken} from "contracts/protocol/tokenization/VariableDebtToken.sol";
import {LendingPoolConfigurator} from "contracts/protocol/pool/LendingPoolConfigurator.sol";

contract PoolTest is DSTest {
    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    LendingPool implementation;
    LendingPool pool;
    LendingPoolAddressesProviderRegistry registry;
    LendingPoolAddressesProvider polygonProvider;
    address configurator;
    AToken aToken;
    StableDebtToken stableDebtToken;
    VariableDebtToken v;
    address admin = address(1234);

    address asset = address(0xD838290e877E0188a4A44700463419ED96c16107);

    function setUp() public {
        vm.startPrank(admin);
        setup_pool();
        setup_tokens();

        vm.stopPrank();
    }

    function setup_pool() public {
        implementation = new LendingPool();
        registry = new LendingPoolAddressesProviderRegistry();
        //get the Polygon provider & register with the registry
        polygonProvider = new LendingPoolAddressesProvider("Polygon");
        registry.registerAddressesProvider(address(polygonProvider), 1);
        //set the admin
        polygonProvider.setPoolAdmin(admin); // set same as owner

        //create a proxy & set the address provider in the proxy to the polygonProvider
        polygonProvider.setLendingPoolImpl(address(implementation));
        //get the proxy
        pool = LendingPool(polygonProvider.getLendingPool());

        // set implementation  & get proxy for the pool configurator
        LendingPoolConfigurator c = new LendingPoolConfigurator();
        polygonProvider.setLendingPoolConfiguratorImpl(address(c));
        configurator = polygonProvider.getLendingPoolConfigurator();
    }

    function setup_tokens() public {
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
            "StableDebt",
            "SD",
            address(0)
        );
        v = new VariableDebtToken(
            address(pool),
            asset,
            "VariableDebt",
            "VD",
            address(0)
        );
    }

    function initCarbonReserve() public {
        vm.prank(admin);
        // this will get all token contracts as proxy & init the reserve for the underlying asset of the aToken
        LendingPoolConfigurator(configurator).initReserve(
            address(aToken),
            address(stableDebtToken),
            address(v),
            18,
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
