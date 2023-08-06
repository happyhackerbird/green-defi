// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {DSTest} from "ds-test/test.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import {LendingPool} from "contracts/protocol/pool/LendingPool.sol";
import {LendingPoolAddressesProviderRegistry} from "contracts/protocol/configuration/LendingPoolAddressesProviderRegistry.sol";
import {LendingPoolAddressesProvider} from "contracts/protocol/configuration/LendingPoolAddressProvider.sol";
import {AToken} from "contracts/protocol/tokenization/AToken.sol";
import {StableDebtToken} from "contracts/protocol/tokenization/StableDebtToken.sol";
import {VariableDebtToken} from "contracts/protocol/tokenization/VariableDebtToken.sol";
import {LendingPoolConfigurator} from "contracts/protocol/pool/LendingPoolConfigurator.sol";
import {DefaultReserveInterestRateStrategy} from "contracts/protocol/pool/DefaultReserveInterestRateStrategy.sol";
import {PriceOracle} from "contracts/mocks/oracle/PriceOracle.sol";
import {MockAggregator} from "contracts/mocks/oracle/CLAggregators/MockAggregator.sol";
import {LendingRateOracle} from "contracts/mocks/oracle/LendingRateOracle.sol";

import {IERC20} from "contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {DataTypes} from "contracts/protocol/libraries/types/DataTypes.sol";

contract PoolTest is Test {
    LendingPool implementation;
    LendingPool pool;
    LendingPoolAddressesProviderRegistry registry;
    LendingPoolAddressesProvider polygonProvider;
    address configurator;
    AToken aToken;
    StableDebtToken stableDebtToken;
    VariableDebtToken variableDebtToken;
    DefaultReserveInterestRateStrategy strategy;
    address admin = address(1234);
    address asset = address(0xD838290e877E0188a4A44700463419ED96c16107);

    address user = address(123);

    uint constant WEEK = 1 weeks;

    event Deposit(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint16 indexed referral
    );

    event Withdraw(
        address indexed reserve,
        address indexed user,
        address indexed to,
        uint256 amount
    );

    event Borrow(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 borrowRateMode,
        uint256 borrowRate,
        uint16 indexed referral
    );

    event Repay(
        address indexed reserve,
        address indexed user,
        address indexed repayer,
        uint256 amount
    );

    function setUp() public {
        vm.startPrank(admin);
        setup_pool();
        setup_tokens();
        setup_interestRateStrategy();
        setup_oracle();
                setup_carbonReserve();

        vm.stopPrank();

// setup funds
        deal(asset, address(this), 10e27);
        IERC20(asset).approve(address(pool), 10e27);

        deal(asset, address(user), 1e27);
        vm.prank(user);
        IERC20(asset).approve(address(pool), 1e27);
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
        variableDebtToken = new VariableDebtToken(
            address(pool),
            asset,
            "VariableDebt",
            "VD",
            address(0)
        );
    }

    function setup_interestRateStrategy() public {
        strategy = new DefaultReserveInterestRateStrategy(
            polygonProvider,
            8 * 1e26,
            0,
            4 * 1e25,
            75 * 1e25,
            2 * 1e25,
            75 * 1e25
        );
    }

    function setup_oracle() public {
        PriceOracle fallbackOracle = new PriceOracle();
        fallbackOracle.setEthUsdPrice(5848466240000000);
        fallbackOracle.setAssetPrice(asset, 10000);
        MockAggregator aggregator = new MockAggregator(10000);

        LendingRateOracle lendingRateOracle = new LendingRateOracle();

        polygonProvider.setPriceOracle(address(fallbackOracle));
        polygonProvider.setLendingRateOracle(address(lendingRateOracle));
    }

    function setup_carbonReserve() public {
        // this will get all token contracts as proxy & init the reserve for the underlying asset of the aToken
        LendingPoolConfigurator(configurator).initReserve(
            address(aToken),
            address(stableDebtToken),
            address(variableDebtToken),
            18,
            address(strategy)
        );
    }

    function test_setup() public {
        assertReserve(1e27, 1e27, 0, 0);
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
        uint amount = 100e18;
        vm.expectEmit(true, true, true, true);
        emit Deposit(asset, address(this), address(this), amount, 0);
        pool.deposit(asset, amount, address(this), 0);
        assertReserve(1e27, 1e27, 0, 0);

        //get newly minted tokens
        uint bal = AToken(aToken).scaledBalanceOf(address(this));
        assertEq(bal, amount);

        // get balance + interest
        bal = AToken(aToken).balanceOf(address(this));
        assertEq(bal, amount);

// deposit on behalf of another user & check balance
        pool.deposit(asset, 5e18, address(user), 0);
        bal = AToken(aToken).balanceOf(address(user));
        assertEq(bal, 5e18);
    }

    function test_interestRateCalculation() public {
        uint amount = 100e18;
        pool.deposit(asset, amount, address(this), 0);

        // at the start, reserve indices are initiliazed to 1e27 = 1 ray
        assertReserve(1e27, 1e27, 0, 0);

        // return token + interest; 0 interest because no time has passed & no action taken yet 
        uint bal = AToken(aToken).balanceOf(address(this));
        assertEq(bal, amount);

// 5 weeks have passed
        vm.warp(block.timestamp + 500 * WEEK);
        // deposit more liquidity - recalculates liquidity index
        pool.deposit(asset, 50e18, address(user), 0);
        bal = AToken(aToken).balanceOf(address(user));
        assertEq(bal, 50e18);
        // assert that the liquidity index has been updated
        assertReserve(1e27, 1e27, 0, 0);

    }

    function test_borrow() public {
        test_deposit();
        pool.borrow(asset, 100, 2, 0, address(this));
    }

    function assertReserve(
        uint liquidityIndex,
        uint variableBorrowIndex,
        uint currentLiquidityRate,
        uint currentVariableBorrowRate
    ) public {
        DataTypes.ReserveData memory reserve = pool.getReserveData(asset);
        assertEq(reserve.liquidityIndex, liquidityIndex);
        assertEq(reserve.variableBorrowIndex, variableBorrowIndex);
        assertEq(reserve.currentLiquidityRate, currentLiquidityRate);
        assertEq(reserve.currentVariableBorrowRate, currentVariableBorrowRate);

        aToken = AToken(reserve.aTokenAddress);
    }
}
