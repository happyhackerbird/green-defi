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

    event Withdraw(address indexed provider, uint value, uint ts);

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

    // test a single createLock action with projected changes of voting power
    function test_createLock_Single() external {
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

        // check the lock was assigned properly for the user
        (int128 amt, uint end) = ve.lockedBalances(address(user));
        assertEq(amt, 5 * 1e18);
        assertEq(end, endWeeks);

        // check voting power calculation for the user
        // rate of change based on the locked amount
        int128 calculatedSlope = int128(5 * 1e18) / iMAXTIME;
        // accumulated voting power at this point in time
        int128 calculatedBias = calculatedSlope *
            int128(int(endWeeks - block.timestamp));
        // stored as last checkpoint
        (int128 bias, int128 slope, uint256 ts) = ve.getLastUserPoint(
            address(user)
        );
        assertEq(bias, calculatedBias);
        assertEq(slope, calculatedSlope);
        assertEq(ts, block.timestamp);

        // check voting power
        // at current time
        int128 bal = SafeCast.toInt128(int(ve.currentBalance(address(user))));
        assertEq(bal, calculatedBias);

        // the scheduled slope change at the end of the lock, this removes the effect of the lock globally
        assertEq(ve.slopeChanges(endWeeks), -calculatedSlope);

        // check voting power at a later time and assert that its less
        bal = SafeCast.toInt128(
            int(ve.balanceOfAt(address(user), block.timestamp + 25 weeks))
        );
        assertLt(bal, calculatedBias);

        // check voting power at the end of the lock and assert that its 0
        bal = SafeCast.toInt128(
            int(ve.balanceOfAt(address(user), projectedEnd))
        );
        assertEq(bal, 0);

        // check the global state: epoch, pointHistory, global voting power
        assertEq(ve.globalEpoch(), 1);
        // assertEq(ve.pointHistory(address(user)), (bias, slope, ts));
        // totalsupply
    }

    function test_createLock_Multiple() public {
        vm.warp(_getWeeksAfter(1));
        uint amount = 5 * 1e18;
        int128 i_amount = 5 * 1e18;
        uint end1 = _getWeeksAfter(52);
        uint end2 = _getWeeksAfter(104);

        // first user creates lock
        vm.startPrank(user);
        token.approve(address(ve), amount);
        ve.createLock(amount, end1);
        vm.stopPrank();
        int128 slope1 = i_amount / iMAXTIME;
        int128 bias1 = slope1 * int128(int(end1 - block.timestamp));

        // next block
        vm.roll(1);
        // another user creates lock
        vm.startPrank(user2);
        token.approve(address(ve), amount);
        ve.createLock(amount, end2);
        vm.stopPrank();

        int128 slope2 = i_amount / iMAXTIME;
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
        assertEq(1, ve.userPointEpoch(address(user2))); // notice that the epoch is always counted individually for each user

        // check accumulated history
        (bias, slope, , ) = ve.pointHistory(1);
        assertEq(bias, bias1);
        assertEq(slope, slope1);
        (bias, slope, , ) = ve.pointHistory(2);
        // StdAssertions.assertApproxEqRel(
        //     bias,
        //     bias1 - ((1 weeks) * slope1) + bias2,
        //     3e18
        // );
        // because the lock is created less than a week in time after the first one, there is no reduction in voting power from the first lock yet
        assertEq(bias, bias1 - 0 + bias2);
        // the slope grows by the second lock
        assertEq(slope, slope1 + slope2);

        // // check the global state: epoch, pointHistory, global voting power
        assertEq(ve.globalEpoch(), 2);
        // assertEq(ve.totalSupplyAt(block.timestamp), bias1 + bias2);
    }

    // this test illustrates how the slope and biases change over time and when locks end
    function test_createLock_SlopeChange() public {
        vm.warp(_getWeeksAfter(1));
        uint amount = 5 * 1e18;
        uint end1 = _getWeeksAfter(52);
        uint time = _getWeeksAfter(51);
        uint t = block.timestamp;

        // first user creates lock
        vm.startPrank(user);
        token.approve(address(ve), amount);
        ve.createLock(amount, end1);
        vm.stopPrank();

        // assert voting power
        int128 i_amount = 5 * 1e18;
        int128 slope1 = i_amount / iMAXTIME;
        int128 bias1 = slope1 * int128(int(end1 - block.timestamp));
        int128 bal = SafeCast.toInt128(int(ve.currentBalance(address(user))));
        assertEq(bal, bias1);

        // set time to one week before lock ends (51 weeks)
        vm.warp(time);

        // second user creates lock
        token.approve(address(ve), amount);
        ve.createLock(amount, end1);
        // assert user voting power
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
        (bias, slope, ts) = ve.getLastUserPoint(address(this));
        assertEq(bias, bias2);
        assertEq(slope, slope2);

        // check accumulated history
        // first epoch
        (bias, slope, , ) = ve.pointHistory(1);
        assertEq(bias, bias1); // cumulative voting power from first lock
        assertEq(slope, slope1);
        // second epoch
        (bias, slope, , ) = ve.pointHistory(2);
        // first lock voting power decreases by 1 week
        assertEq(bias, bias1 - (1 weeks * slope1));
        assertEq(slope, slope1);
        // 51 epoch
        (bias, slope, , ) = ve.pointHistory(51);
        assertEq(bias, bias1 - (50 weeks * slope1));
        assertEq(slope, slope1); // slope still remains unchanged
        // 52 epoch - at this epoch the slope changes because the first lock expires
        (bias, slope, , ) = ve.pointHistory(52);
        // this checkpoint accounts for the other lock - total voting power has increased at this point
        assertEq(bias, bias1 - (51 weeks * slope1) + bias2);
        // the slope now accounts for the second lock too ()
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
        assertEq(
            bias,
            bias1 -
                (51 weeks * slope1) +
                bias2 -
                (slope1 + slope2) *
                1 weeks +
                bias3
        );
        // the
        assertEq(slope, slope2);

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

    function test_revert_createLock_InvalidParameters() public {
        // zero amount
        uint end1 = _getWeeksAfter(52);
        vm.expectRevert("Stake must be non-zero amount");
        ve.createLock(0, end1);

        // no funds
        uint amount = 5 * 1e18;
        vm.expectRevert("Not enough GREEN balance");
        ve.createLock(amount, end1);

        // duration too short
        token.approve(address(ve), amount);
        vm.expectRevert("Duration must be at least one week");
        ve.createLock(amount, block.timestamp);

        // duration too long
        vm.expectRevert("Duration can be one year at most");
        ve.createLock(amount, _getWeeksAfter(52 * 4 + 1));
    }

    function test_increaseTime() public {
        uint amount = 5 * 1e18;
        uint end1 = _getWeeksAfter(52);
        uint end2 = _getWeeksAfter(52 * 2); // extend lock by 1 year

        token.approve(address(ve), amount);
        ve.createLock(amount, end1);

        // assert balance with initial amount
        int128 calculatedSlope = int128(5 * 1e18) / iMAXTIME;
        int128 calculatedBias = calculatedSlope *
            int128(int(end1 - block.timestamp));
        int128 bal = SafeCast.toInt128(int(ve.currentBalance(address(this))));
        assertEq(bal, calculatedBias);

        // increase amount after a block
        vm.roll(1);
        vm.expectEmit(true, true, true, true);
        emit Deposit(
            address(this),
            0,
            end2,
            LockAction.INCREASE_LOCK_TIME,
            block.timestamp
        );
        ve.increaseTime(end2);

        // assert balance with updated time (also checks user point history)
        // if the user extends their lock they gain more voting power
        calculatedBias = calculatedSlope * int128(int(end2 - block.timestamp));
        assertLt(bal, calculatedBias);
        bal = SafeCast.toInt128(int(ve.currentBalance(address(this))));
        assertEq(bal, calculatedBias);

        // the last checkpoint has the correct updated bias
        (int128 bias, , , ) = ve.pointHistory(2);
        assertEq(bias, calculatedBias);

        // slope change schedules are updated
        assertEq(ve.slopeChanges(end2), -calculatedSlope);
        assertEq(ve.slopeChanges(end1), 0);
    }

    function test_revert_increaseTime_Invalid() public {
        vm.expectRevert("No lock found");
        ve.increaseTime(_getWeeksAfter(52));

        token.approve(address(ve), 5 * 1e18);
        ve.createLock(5 * 1e18, _getWeeksAfter(2));

        vm.expectRevert("New time must be after old");
        ve.increaseTime(_getWeeksAfter(1));

        vm.expectRevert("Maximum locking duration four years");
        ve.increaseTime(_getWeeksAfter(52 * 4 + 1));

        vm.warp(_getWeeksAfter(2));
        vm.expectRevert("Lock is expired, withdraw first");
        ve.increaseTime(_getWeeksAfter(4));
    }

    function test_increaseAmount() public {
        uint amount = 5 * 1e18;
        uint end1 = _getWeeksAfter(52);

        token.approve(address(ve), amount);
        ve.createLock(amount, end1);

        // assert balance with initial amount
        int128 calculatedSlope = int128(5 * 1e18) / iMAXTIME;
        int128 calculatedBias = calculatedSlope *
            int128(int(end1 - block.timestamp));
        int128 bal = SafeCast.toInt128(int(ve.currentBalance(address(this))));
        assertEq(bal, calculatedBias);

        // increase amount after a block
        vm.roll(1);
        token.approve(address(ve), amount);

        vm.expectEmit(true, true, true, true);
        emit Deposit(
            address(this),
            amount,
            end1,
            LockAction.INCREASE_LOCK_AMOUNT,
            block.timestamp
        );
        ve.increaseAmount(amount);

        // assert balance with updated amount (also checks user point history)
        calculatedSlope = int128(10 * 1e18) / iMAXTIME;
        calculatedBias = calculatedSlope * int128(int(end1 - block.timestamp));
        bal = SafeCast.toInt128(int(ve.currentBalance(address(this))));
        assertEq(bal, calculatedBias);

        // the last checkpoint has the correct updated slope
        (int128 bias, int128 slope, , ) = ve.pointHistory(2);
        assertEq(bias, calculatedBias);
        assertEq(slope, calculatedSlope);

        // scheduled slope change is updated
        slope = ve.slopeChanges(end1);
        assertEq(slope, -calculatedSlope);
    }

    function test_revert_increaseAmount_Invalid() public {
        uint amount = 5 * 1e18;
        vm.expectRevert("No lock found");
        ve.increaseAmount(amount);

        token.approve(address(ve), 5 * 1e18);
        ve.createLock(5 * 1e18, _getWeeksAfter(2));

        vm.expectRevert("Amount must be non-zero");
        ve.increaseAmount(0);

        // no funds
        vm.expectRevert("Not enough GREEN balance");
        ve.increaseAmount(amount);

        vm.warp(_getWeeksAfter(2));
        vm.expectRevert("Lock is expired, withdraw first");
        ve.increaseAmount(amount);
    }

    function test_checkpoint_Global() public {
        uint startTime = _getWeeksAfter(1);
        vm.warp(startTime); // set to start at first week
        uint amount = 5 * 1e18;
        uint end1 = _getWeeksAfter(52);
        uint time = _getWeeksAfter(51);

        token.approve(address(ve), amount);
        ve.createLock(amount, end1);

        // calculate voting power from users lcok
        int128 i_amount = 5 * 1e18;
        int128 slope1 = i_amount / iMAXTIME;
        int128 bias1 = slope1 * int128(int(end1 - block.timestamp));
        int128 bal = SafeCast.toInt128(int(ve.currentBalance(address(this))));
        assertEq(bal, bias1);

        // set time and trigger global checkpoint
        vm.warp(time);
        ve.checkpoint();

        // individual user history hasnt been affected by the global checkpoint call
        int128 bias;
        int128 slope;
        uint256 ts;
        (bias, slope, ts) = ve.getLastUserPoint(address(this));
        assertEq(bias, bias1);
        assertEq(slope, slope1);
        assertEq(ts, startTime);

        // check accumulated history
        // first epoch
        (bias, slope, , ) = ve.pointHistory(1);
        assertEq(bias, bias1);
        assertEq(slope, slope1);
        // 51 epoch
        (bias, slope, , ) = ve.pointHistory(51);
        assertEq(bias, bias1 - (50 weeks * slope1));
        assertEq(slope, slope1);
        // 52 epoch
        (bias, slope, , ) = ve.pointHistory(52);
        assertEq(bias, bias1 - (51 weeks * slope1));
        assertEq(slope, slope1);
        // 53 epoch - slope is 0 bc lock expired
        (bias, slope, , ) = ve.pointHistory(53);
        assertEq(slope, 0);
    }

    function test_balanceOfAt() public {
        // 0 user epoch
        assertEq(ve.balanceOfAt(address(this), _getWeeksAfter(1)), 0);

        uint startTime = _getWeeksAfter(1);
        vm.warp(startTime); // set to start at first week
        uint amount = 5 * 1e18;
        uint end1 = _getWeeksAfter(52);
        token.approve(address(ve), amount);
        ve.createLock(amount, end1);

        // calculate voting power from users lcok
        int128 i_amount = 5 * 1e18;
        int128 slope1 = i_amount / iMAXTIME;
        int128 bias1 = slope1 * int128(int(end1 - startTime));

        // at current time
        int128 bal = SafeCast.toInt128(
            int(ve.balanceOfAt(address(this), startTime))
        );
        assertEq(bal, bias1);
        // at future time
        bal = SafeCast.toInt128(
            int(ve.balanceOfAt(address(this), _getWeeksAfter(2)))
        );
        assertEq(bal, bias1 - (2 weeks * slope1));
        // warp time and check at past time
        vm.warp(_getWeeksAfter(2));
        bal = SafeCast.toInt128(int(ve.balanceOfAt(address(this), startTime)));
        assertEq(bal, bias1);
    }

    function test_withdraw() public {
        uint amount = 5 * 1e18;
        uint end1 = _getWeeksAfter(52);
        token.approve(address(ve), amount);
        ve.createLock(amount, end1);

        token.approve(address(ve), amount);
        ve.increaseAmount(amount);

        end1 = _getWeeksAfter(52 * 2);
        ve.increaseTime(end1);

        int128 calculatedSlope = int128(10 * 1e18) / iMAXTIME;
        int128 calculatedBias = calculatedSlope *
            int128(int(end1 - block.timestamp));
        int128 bal = SafeCast.toInt128(int(ve.currentBalance(address(this))));
        assertEq(bal, calculatedBias);

        assertEq(token.balanceOf(address(this)), (1000 - 10) * 1e18);

        // expire the lock and withdraw
        vm.warp(end1);
        bal = SafeCast.toInt128(int(ve.currentBalance(address(this))));
        assertEq(bal, 0);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(address(this), amount * 2, block.timestamp);
        ve.withdraw();
        assertEq(token.balanceOf(address(this)), 1000 * 1e18);
    }

    function test_revert_withdraw_Invalid() public {
        uint amount = 5 * 1e18;
        uint end1 = _getWeeksAfter(52);
        token.approve(address(ve), amount);
        ve.createLock(amount, end1);

        vm.expectRevert("Lock hasn't expired yet");
        ve.withdraw();
    }

    // Helpers

    // calculate timestamp at the end of x weeks after current time
    function _getWeeksAfter(uint x) internal returns (uint256) {
        return (block.timestamp / 1 weeks + x) * 1 weeks;
    }
}
