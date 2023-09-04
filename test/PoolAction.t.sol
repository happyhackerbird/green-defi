// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/console.sol";
import {PoolConfigurationTest} from "test/PoolConfiguration.t.sol";
import {IERC20} from "contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {AToken} from "contracts/protocol/tokenization/AToken.sol";
import {DebtTokenBase} from "contracts/protocol/tokenization/base/DebtTokenBase.sol";

contract PoolActionTest is PoolConfigurationTest {
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

    function test_borrow() public {
        // deposit enough assets
        uint amount = 100e18;
        pool.deposit(NCT, amount, address(this), 0);
        pool.deposit(MOSS, amount, address(this), 0);
        amount = 150e18;
        pool.deposit(NCT, amount, address(user), 0);
        // configure asset as collateral
        vm.prank(user);
        pool.setUserUseReserveAsCollateral(NCT, true);

        // user borrows
        amount = 1e18;
        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit Borrow(MOSS, address(user), address(user), amount, 1, 0, 0);
        pool.borrow(MOSS, amount, 1, 0, address(user));
        vm.stopPrank();

        // // set borrow allowance
        // vm.prank(user);
        // DebtTokenBase(stableDebtToken).approveDelegation(address(this), 2e18);
        // // borrow on behalf of user
        // pool.borrow(MOSS, amount, 1, 0, address(user));
    }

    function test_interestRateCalculation() public {
        uint amount = 100e18;
        assertReserve(NCT, 1e27, 1e27, 0, 0);
        pool.deposit(NCT, amount, address(this), 0);

        pool.deposit(MOSS, amount, address(this), 0);

        // at the start, reserve indices are initiliazed to 1e27 = 1 ray
        assertReserve(NCT, 1e27, 1e27, 0, 0);

        // return token + interest; 0 interest because no time has passed & no action taken yet
        uint bal = AToken(aToken).balanceOf(address(this));
        assertEq(bal, amount);

        // borrow in order to get a positive liquidity index
        pool.deposit(NCT, amount, address(user), 0);
        vm.startPrank(user);
        pool.setUserUseReserveAsCollateral(NCT, true);
        pool.borrow(MOSS, 1e18, 1, 0, address(user));
        vm.stopPrank();

        // 5 weeks have passed,
        vm.warp(block.timestamp + 500 * WEEK);
        // so at this action it should recalculate liquidity index
        pool.deposit(NCT, amount, address(user), 0);

        // assert interest has accrued
        bal = AToken(aToken).balanceOf(address(this));
        assertEq(bal, amount);
        console.log("balance", bal);
        bal = AToken(aToken).balanceOf(address(user));
        console.log("balance user", bal);

        // assert that the liquidity index has been updated
        // assertReserve(NCT, 1e27, 1e27, 0, 0);
    }

    function test_repay() public {
        // deposit enough assets
        uint amount = 100e18;
        pool.deposit(NCT, amount, address(this), 0);
        pool.deposit(MOSS, amount, address(this), 0);
        amount = 50e18;
        pool.deposit(NCT, amount, address(user), 0);
        // configure asset as collateral
        vm.prank(user);
        pool.setUserUseReserveAsCollateral(NCT, true);

        // user & repays
        amount = 1e18;
        vm.startPrank(user);
        pool.borrow(MOSS, amount, 1, 0, address(user));
        vm.expectEmit(true, true, true, true);
        emit Repay(MOSS, address(user), address(user), amount);
        pool.repay(MOSS, amount, 1, address(user));
        vm.stopPrank();
    }

    function test_withdraw() public {
        // deposit enough assets
        uint amount = 100e18;
        pool.deposit(NCT, amount, address(this), 0);
        vm.expectEmit(true, true, true, true);
        emit Withdraw(NCT, address(this), address(this), 50e18);
        pool.withdraw(NCT, 50e18, address(this));
        uint bal = AToken(aToken).balanceOf(address(this));
        assertEq(bal, 50e18);
    }
}
