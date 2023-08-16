// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

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

contract PoolConfigurationTest is Test {
    LendingPool implementation;
    LendingPool pool;
    LendingPoolAddressesProviderRegistry registry;
    LendingPoolAddressesProvider polygonProvider;
    address configurator;
    AToken aToken;
    AToken aToken2;
    StableDebtToken stableDebtToken;
    StableDebtToken stableDebtToken2;
    VariableDebtToken variableDebtToken;
    VariableDebtToken variableDebtToken2;

    DefaultReserveInterestRateStrategy strategy;
    address admin = address(1234);
    address constant NCT = address(0xD838290e877E0188a4A44700463419ED96c16107);
    address constant MOSS = address(0xAa7DbD1598251f856C12f63557A4C4397c253Cea);

    address user = address(123);

    uint constant WEEK = 1 weeks;

    uint256 constant OPTIMAL_UTILIZATION_RATE = 800000000000000000; // 80%
    uint256 constant EXCESS_UTILIZATION_RATE = 200000000000000000; // 20%
    uint256 constant BASE_VARIABLE_BORROW_RATE = 10000000000000000; // 1%
    uint256 constant VARIABLE_RATE_SLOPE1 = 50000000000000000; // 5%
    uint256 constant VARIABLE_RATE_SLOPE2 = 100000000000000000; // 10%
    uint256 constant STABLE_RATE_SLOPE1 = 20000000000000000; // 2%
    uint256 constant STABLE_RATE_SLOPE2 = 40000000000000000; // 4%

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
        deal(NCT, address(this), 10e27);
        IERC20(NCT).approve(address(pool), 10e27);

        deal(MOSS, address(this), 10e27);
        IERC20(MOSS).approve(address(pool), 10e27);

        deal(NCT, address(user), 1e27);
        deal(MOSS, address(user), 1e27);
        vm.startPrank(user);
        IERC20(NCT).approve(address(pool), 1e27);
        IERC20(MOSS).approve(address(pool), 1e27);
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
        aToken = new AToken(pool, NCT, address(0), "carbonA", "CA", address(0));
        aToken2 = new AToken(
            pool,
            MOSS,
            address(0),
            "carbonB",
            "CB",
            address(0)
        );

        stableDebtToken = new StableDebtToken(
            address(pool),
            NCT,
            "StableDebt",
            "SD",
            address(0)
        );
        stableDebtToken2 = new StableDebtToken(
            address(pool),
            MOSS,
            "StableDebt2",
            "SD2",
            address(0)
        );

        variableDebtToken = new VariableDebtToken(
            address(pool),
            NCT,
            "VariableDebt",
            "VD",
            address(0)
        );
        variableDebtToken2 = new VariableDebtToken(
            address(pool),
            MOSS,
            "VariableDebt2",
            "VD2",
            address(0)
        );
    }

    function setup_interestRateStrategy() public {
        // strategy = new DefaultReserveInterestRateStrategy(
        //     polygonProvider,
        // 8 * 1e26,
        // 0,
        // 4 * 1e25,
        // 75 * 1e25,
        // 2 * 1e25,
        // 75 * 1e25
        // );
        strategy = new DefaultReserveInterestRateStrategy(
            polygonProvider,
            OPTIMAL_UTILIZATION_RATE,
            BASE_VARIABLE_BORROW_RATE,
            VARIABLE_RATE_SLOPE1,
            VARIABLE_RATE_SLOPE2,
            STABLE_RATE_SLOPE1,
            STABLE_RATE_SLOPE2
        );
    }

    function setup_oracle() public {
        PriceOracle fallbackOracle = new PriceOracle();
        fallbackOracle.setEthUsdPrice(5848466240000000);
        //price 8.8.23
        fallbackOracle.setAssetPrice(NCT, 860000 * 1e9);
        fallbackOracle.setAssetPrice(MOSS, 610000 * 1e9);
        MockAggregator aggregator = new MockAggregator(300 * 1e9);

        LendingRateOracle lendingRateOracle = new LendingRateOracle();

        polygonProvider.setPriceOracle(address(fallbackOracle));
        polygonProvider.setLendingRateOracle(address(lendingRateOracle));
    }

    function setup_carbonReserve() public {
        // this will get all token contracts as proxy & init the reserve for the underlying NCT of the aToken
        LendingPoolConfigurator(configurator).initReserve(
            address(aToken),
            address(stableDebtToken),
            address(variableDebtToken),
            18,
            address(strategy)
        );
        LendingPoolConfigurator(configurator).enableBorrowingOnReserve(
            NCT,
            true
        );
        LendingPoolConfigurator(configurator).configureReserveAsCollateral(
            NCT,
            7500, // LTV
            9000, // Liquidation threshold
            10500 // 5% liquidation bonus
        );

        LendingPoolConfigurator(configurator).initReserve(
            address(aToken2),
            address(stableDebtToken2),
            address(variableDebtToken2),
            18,
            address(strategy)
        );
        LendingPoolConfigurator(configurator).enableBorrowingOnReserve(
            MOSS,
            true
        );
        // LendingPoolConfigurator(configurator).configureReserveAsCollateral(
        //     MOSS,
        //     7500,
        //     9000,
        //     10500
        // );

        // get aToken proxies
        DataTypes.ReserveData memory reserve = pool.getReserveData(NCT);
        aToken = AToken(reserve.aTokenAddress);
        stableDebtToken = StableDebtToken(reserve.stableDebtTokenAddress);
        reserve = pool.getReserveData(MOSS);
        aToken2 = AToken(reserve.aTokenAddress);
        stableDebtToken2 = StableDebtToken(reserve.stableDebtTokenAddress);
    }

    function test_setup() public {
        // at the start liqudity index and variable borrow index is initialized to one ray
        assertReserve(NCT, 1e27, 1e27, 0, 0);
        assertReserve(MOSS, 1e27, 1e27, 0, 0);
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

    // helper
    function assertReserve(
        address asset,
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
    }
}
