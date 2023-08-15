// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/console.sol";
import {PoolConfigurationTest} from "test/PoolConfiguration.t.sol";
import {IERC20} from "contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {AToken} from "contracts/protocol/tokenization/AToken.sol";

contract PoolActionTest is PoolConfigurationTest {
    // DefaultReserveInterestRateStrategy strategy;
    // address admin = address(1234);
    // address constant NCT = address(0xD838290e877E0188a4A44700463419ED96c16107);
    // address constant MOSS = address(0xAa7DbD1598251f856C12f63557A4C4397c253Cea);

    // address user = address(123);

    // uint constant WEEK = 1 weeks;

    function test_deposit() public {
        uint amount = 100e18;
        vm.expectEmit(true, true, true, true);
        emit Deposit(NCT, address(this), address(this), amount, 0);
        pool.deposit(NCT, amount, address(this), 0);

        //get newly minted tokens
        uint bal = AToken(aToken).scaledBalanceOf(address(this));
        assertEq(bal, amount);

        // get balance + interest
        bal = AToken(aToken).balanceOf(address(this));
        assertEq(bal, amount);

        // deposit on behalf of another user & check balance
        amount = 5e18;
        pool.deposit(NCT, amount, address(user), 0);
        bal = AToken(aToken).balanceOf(address(user));
        assertEq(bal, amount);
    }

    function test_interestRateCalculation() public {
        uint amount = 100e18;
        pool.deposit(NCT, amount, address(this), 0);

        // at the start, reserve indices are initiliazed to 1e27 = 1 ray
        assertReserve(NCT, 1e27, 1e27, 0, 0);

        // return token + interest; 0 interest because no time has passed & no action taken yet
        uint bal = AToken(aToken).balanceOf(address(this));
        assertEq(bal, amount);

        // 5 weeks have passed, making time pass should update LI at next action
        vm.warp(block.timestamp + 500 * WEEK);
        // deposit more liquidity - recalculates liquidity index
        pool.deposit(NCT, 50e18, address(user), 0);
        bal = AToken(aToken).balanceOf(address(user));
        assertEq(bal, 50e18);
        // assert that the liquidity index has been updated
        // assertReserve(NCT, 1e27, 1e27, 0, 0);
    }

    function test_borrow() public {
        uint amount = 100e18;
        pool.deposit(NCT, amount, address(this), 0);
        // vm.prank(admin);
        pool.deposit(MOSS, amount, address(this), 0);

        amount = 50e18;
        pool.deposit(NCT, amount, address(user), 0);
        pool.setUserUseReserveAsCollateral(NCT, true);

        amount = 1e18;
        vm.startPrank(user);
        // IERC20(aToken).approve(address(pool), 1e18);
        pool.setUserUseReserveAsCollateral(NCT, true);
        vm.expectEmit(true, true, true, true);
        emit Borrow(MOSS, address(user), address(user), amount, 1, 0, 0);
        pool.borrow(MOSS, amount, 1, 0, address(user));
        vm.stopPrank();

        pool.borrow(MOSS, amount, 1, 0, address(user));
    }

    function test_repay() public {
        uint amount = 100e18;
        pool.deposit(NCT, amount, address(this), 0);
        pool.deposit(MOSS, amount, address(this), 0);

        pool.deposit(NCT, 50e18, address(user), 0);

        vm.startPrank(user);
        // IERC20(aToken).approve(address(pool), 1e18);
        pool.setUserUseReserveAsCollateral(NCT, true);
        pool.borrow(MOSS, 1e18, 1, 0, address(user));
        pool.deposit(NCT, amount, address(this), 0);
        vm.prank(admin);
        pool.deposit(MOSS, amount, address(admin), 0);
        pool.deposit(NCT, 50e18, address(user), 0);
        pool.setUserUseReserveAsCollateral(NCT, true);

        vm.startPrank(user);
        // IERC20(aToken).approve(address(pool), 1e18);
        pool.setUserUseReserveAsCollateral(NCT, true);
        pool.borrow(MOSS, 1e18, 1, 0, address(user));
        // borrow on behalf of TestContract
        console.log("borrowing");
        pool.borrow(MOSS, 1e18, 1, 0, address(this));
        vm.stopPrank();

        pool.repay(MOSS, 1e18, 1, address(user));
        vm.stopPrank();
    }

    function test_withdraw() public {
        pool.deposit(NCT, 100e18, address(this), 0);
        pool.deposit(MOSS, 100e18, address(this), 0);

        pool.deposit(NCT, 50e18, address(user), 0);

        vm.startPrank(user);
        // IERC20(aToken).approve(address(pool), 1e18);
        pool.setUserUseReserveAsCollateral(NCT, true);
        pool.borrow(MOSS, 1e18, 1, 0, address(user));
        pool.repay(MOSS, 1e18, 1, address(user));
        pool.withdraw(MOSS, 1e18, address(user));
        vm.stopPrank();
    }
}
