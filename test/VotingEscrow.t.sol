//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {VotingEscrow} from "contracts/protocol/governance/VotingEscrow.sol";
import {ERC20} from "contracts/dependencies/openzeppelin/contracts/ERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/SafeCast.sol";

contract VotingEscrowTest is Test {
    ERC20 token;
    VotingEscrow ve;
    address public user = address(0x5E11E1); // random address
    address public user2 = address(0x5E11E2); // random address
    int128 internal constant iMAXTIME = 4 * 365 * 86400;

    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 unlockTime,
        LockAction indexed action,
        uint256 ts
    );

    enum LockAction {
        CREATE_LOCK,
        INCREASE_LOCK_AMOUNT,
        INCREASE_LOCK_TIME
    }

    function setUp() public {
        token = new ERC20("Green", "GRN");
        ve = new VotingEscrow(address(token));

        // deposit funds into user account
        deal(address(token), user, 1000 * 1e18);
        deal(address(token), user2, 1000 * 1e18);
        deal(address(token), address(this), 1000 * 1e18);
    }

    function test_createLock() external {
        uint amount = 5 * 1e18;
        uint projectedEnd = block.timestamp + 1 * 52 weeks; // one year in future
        uint256 endWeeks = (projectedEnd / 1 weeks) * 1 weeks; // floored to week

        // approve funds by user
        vm.startPrank(user);
        token.approve(address(ve), amount);

        // user calls createLock
        vm.expectEmit(true, true, true, true);
        emit Deposit(
            user,
            amount,
            projectedEnd - 1,
            LockAction.CREATE_LOCK,
            block.timestamp
        );
        // loop will have all values at 0, and later the user's lock gets accounted for in the checkpoint
        ve.createLock(amount, projectedEnd);

        // check the lock was stored for the user
        // assertEq(ve.lockedBalances(address(user))[0]);

        // rate of change based on the locked amount
        int128 calculatedSlope = int128(5 * 1e18) / iMAXTIME;
        // accumulated voting power at this point in time
        int128 calculatedBias = calculatedSlope *
            int128(int(endWeeks - block.timestamp));

        (int128 bias, int128 slope, uint256 ts) = ve.getLastUserPoint(
            address(user)
        );
        assertEq(bias, calculatedBias);
        assertEq(slope, calculatedSlope);
        assertEq(ts, block.timestamp);

        int128 bal = SafeCast.toInt128(int(ve.currentBalance(address(user))));
        assertEq(bal, calculatedBias);

        // the slope is negative; the users voting power decreases linearly over time
        assertEq(ve.slopeChanges(endWeeks), -calculatedSlope);

        // check voting power at a later time and assert that its less
        bal = SafeCast.toInt128(
            int(ve.balanceOfAt(address(user), block.timestamp + 25 weeks))
        );
        assertLt(bal, calculatedBias);

        // check the global state: epoch, pointHistory, global voting power
        assertEq(ve.globalEpoch(), 1);
        // assertEq(ve.pointHistory(address(user)), (bias, slope, ts));
        // totalsupply
    }

    function test_createLock_Multiple() public {
        uint amount = 5 * 1e18;
        uint end1 = _getWeeksAfter(52);
        uint end2 = _getWeeksAfter(104);

        // first user creates lock
        vm.startPrank(user);
        token.approve(address(ve), amount);
        ve.createLock(amount, end1);
        vm.stopPrank();

        vm.roll(2); // move block number by 1
        // another user creates lock
        vm.startPrank(user2);
        token.approve(address(ve), amount);
        ve.createLock(amount, end2);
        vm.stopPrank();

        int128 i_amount = 5 * 1e18;
        int128 slope1 = i_amount / iMAXTIME;
        int128 slope2 = i_amount / iMAXTIME;
        int128 bias1 = slope1 * int128(int(end1 - block.timestamp));
        int128 bias2 = slope2 * int128(int(end2 - block.timestamp));

        // check individual voting power
        int128 bal = SafeCast.toInt128(int(ve.currentBalance(address(user))));
        assertEq(bal, bias1);

        bal = SafeCast.toInt128(int(ve.currentBalance(address(user2))));
        assertEq(bal, bias2);

        int128 bias;
        int128 slope;
        uint256 ts;
        // individual user history
        (bias, slope, ) = ve.getLastUserPoint(address(user));
        assertEq(bias, bias1);
        assertEq(slope, slope1);
        assertEq(1, ve.userPointEpoch(address(user)));
        (bias, slope, ts) = ve.getLastUserPoint(address(user2));
        assertEq(bias, bias2);
        assertEq(slope, slope2);

        // check accumulated history
        (bias, slope, , ) = ve.pointHistory(1);
        assertEq(bias, bias1);
        assertEq(slope, slope1);
        (bias, slope, , ) = ve.pointHistory(2);
        StdAssertions.assertApproxEqRel(
            bias,
            bias1 - ((1 weeks) * slope1) + bias2,
            3e18
        );
        assertEq(slope, slope1 + slope2);

        // // check the global state: epoch, pointHistory, global voting power
        // assertEq(ve.globalEpoch(), 2);
        // assertEq(ve.pointHistory(address(user)), (bias1, slope1, block.timestamp));
        // assertEq(ve.pointHistory(address(user2)), (bias2, slope2, block.timestamp));
        // assertEq(ve.totalSupplyAt(block.timestamp), bias1 + bias2);
    }

    // this test illustrates how the slope and biases change
    function test_createLock_SlopeChange() public {
        uint amount = 5 * 1e18;
        uint end1 = _getWeeksAfter(52);
        uint time = _getWeeksAfter(51);
        uint t = block.timestamp;

        // first user creates lock
        vm.startPrank(user);
        token.approve(address(ve), amount);
        ve.createLock(amount, end1);
        vm.stopPrank();

        int128 i_amount = 5 * 1e18;
        int128 slope1 = i_amount / iMAXTIME;
        int128 bias1 = slope1 * int128(int(end1 - block.timestamp));
        int128 bal = SafeCast.toInt128(int(ve.currentBalance(address(user))));
        assertEq(bal, bias1);

        // set time to one week before lock ends
        vm.warp(time);
        token.approve(address(ve), amount);
        ve.createLock(amount, end1);

        int128 slope2 = i_amount / iMAXTIME;
        int128 bias2 = slope2 * int128(int(end1 - block.timestamp));
        bal = SafeCast.toInt128(int(ve.currentBalance(address(this))));
        assertEq(bal, bias2);

        // individual user history
        int128 bias;
        int128 slope;
        uint256 ts;
        (bias, slope, ts) = ve.getLastUserPoint(address(user));
        assertEq(bias, bias1);
        assertEq(slope, slope1);
        assertEq(ts, t); // was recorded in the past
        assertEq(ve.userPointEpoch(address(user)), 1);
        (bias, slope, ts) = ve.getLastUserPoint(address(this));
        assertEq(bias, bias2);
        assertEq(slope, slope2);
        assertEq(ve.userPointEpoch(address(this)), 1);

        // check accumulated history
        // first epoch
        (bias, slope, , ) = ve.pointHistory(1);
        assertEq(bias, bias1); // cumulative voting power of from first lock
        assertEq(slope, slope1);
        // second epoch
        (bias, slope, , ) = ve.pointHistory(2);
        StdAssertions.assertApproxEqRel(bias, bias1 - (1 weeks * slope1), 1e11); // first lock voting power decreases by 1 week
        assertEq(slope, slope1);
        // 51 epoch
        (bias, slope, , ) = ve.pointHistory(51);
        StdAssertions.assertApproxEqRel(
            bias,
            bias1 - (50 weeks * slope1),
            1e12
        );
        assertEq(slope, slope1); // slope still remains unchanged
        // 52 epoch - at this epoch the slope changes because the first lock expires
        (bias, slope, , ) = ve.pointHistory(52);
        StdAssertions.assertApproxEqRel(
            bias,
            bias1 - (51 weeks * slope1) + bias2, // this checkpoint accounts for the other lock - total voting power has increased at this point
            1e12
        );
        assertEq(slope, slope1 + slope2);

        // now lets create another lock
        vm.warp(_getWeeksAfter(1));
        end1 = _getWeeksAfter(1);
        vm.startPrank(user2);
        token.approve(address(ve), amount);
        ve.createLock(amount, end1);

        // this will add another epoch that accounts for the third lock
        int128 slope3 = i_amount / iMAXTIME;
        int128 bias3 = slope3 * int128(int(end1 - block.timestamp));
        (bias, slope, , ) = ve.pointHistory(53);
        StdAssertions.assertApproxEqRel(
            bias,
            bias1 -
                (51 weeks * slope1) +
                bias2 -
                (slope1 + slope2) *
                1 weeks +
                bias3,
            7e12
        );
        assertEq(slope, slope1);

        //global state
        assertEq(ve.globalEpoch(), 53);
    }

    function test_revert_userCreatesMultipleNewLocks() public {
        uint end1 = _getWeeksAfter(52);
        uint amount = 5 * 1e18;
        token.approve(address(ve), 2 * amount);
        ve.createLock(amount, end1);
        vm.expectRevert("Withdraw old tokens first");
        ve.createLock(amount, end1);
    }

    // calculate timestamp at the end of x weeks after current time
    function _getWeeksAfter(uint x) internal returns (uint256) {
        return (block.timestamp / 1 weeks + x) * 1 weeks;
    }
}
