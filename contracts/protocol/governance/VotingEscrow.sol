// SPDX-License-Identifier: UNLICENSED
pragma solidity >0.8.0;

import {ERC20} from "@openzeppelin-contracts/ERC20.sol";
import {IERC20} from "@openzeppelin-contracts/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/SafeCast.sol";
import {Ownable} from "@openzeppelin-contracts/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/ReentrancyGuard.sol";

import "forge-std/console.sol";

/**
 * @title VotingEscrow
 * @dev VotingEscrow is a non standard ERC20token $veGREEN used to represent the voting power of a user. Users lock $GREEN to obtain $veGREEN. Voting power decreases linearly from the moment of locking.
 * Based on https://github.com/curvefi/curve-dao-contracts/blob/master/doc/README.md
 * Voting weight is equal to w = amount *  t / t_max , so it is dependent on both the locked amount as well as the time locked.
 *
 */
contract VotingEscrow is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for ERC20;

    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 unlockTime,
        LockAction indexed action,
        uint256 ts
    );

    // Shared global state
    address public immutable GREEN;
    uint256 public constant WEEK = 1 weeks;
    // Maximum lock time is 4 years
    uint256 public constant MAXTIME = 4 * 52 * WEEK;
    int128 internal constant iMAXTIME = 4 * 365 * 86400;
    uint256 public constant MULTIPLIER = 10 ** 18;

    // address public blocklist
    // Smart contract addresses which are allowed to deposit
    // One wants to prevent the veGREEN from being tokenized
    mapping(address => bool) public whitelist;

    // Lock state
    // Every time a change in slope or bias occurs, the epoch is increased by 1, and a new checkpoint is recorded in the history
    uint256 public globalEpoch;
    // global voting power history, each index corresponds to an epoch (a specific point in time) at which the voting power is recorded
    Point[1000000000000000000] public pointHistory; // 1e9 * userPointHistory.length
    // track voting power history for individual users
    mapping(address => Point[1000000000]) public userPointHistory;
    // latest recorded epoch for users voting power
    mapping(address => uint256) public userPointEpoch;
    // read to schedule changes in the slope values, these represent changing voting power of user
    mapping(uint256 => int128) public slopeChanges;
    mapping(address => LockedBalance) public lockedBalances;

    // represent a point in time for users voting power
    struct Point {
        int128 bias; // The accumulated voting power at that point in time
        int128 slope; // rate of change of voting power at time
        uint256 ts; // timestamp of point
        uint256 blk; // block number
    }

    struct LockedBalance {
        int128 amount;
        uint end;
    }

    enum LockAction {
        CREATE_LOCK,
        INCREASE_LOCK_AMOUNT,
        INCREASE_LOCK_TIME
    }

    constructor(address greenToken) ERC20("Vote-Escrow GREEN", "veGREEN") {
        GREEN = greenToken;
        pointHistory[0] = Point({
            bias: int128(0),
            slope: int128(0),
            ts: block.timestamp,
            blk: block.number
        });
    }

    function addToWhitelist(address addr) external onlyOwner {
        whitelist[addr] = true;
    }

    function removeFromWhitelist(address addr) external onlyOwner {
        whitelist[addr] = false;
    }

    /**************************Getters************************************/

    /**
     * @dev Gets last recorded voting power of user
     * @param addr User address
     * @return bias accumulated power at that time
     * @return slope rate of change at time
     * @return ts time point it was locked
     */
    function getLastUserPoint(
        address addr
    ) external view returns (int128 bias, int128 slope, uint256 ts) {
        uint256 uepoch = userPointEpoch[addr];
        if (uepoch == 0) {
            return (0, 0, 0);
        }
        Point memory point = userPointHistory[addr][uepoch];
        return (point.bias, point.slope, point.ts);
    }

    /**************************Lockup************************************/

    /**
     * @dev Trigger global checkpoint
     */
    function checkpoint() external {
        LockedBalance memory empty;
        _checkpoint(address(0), empty, empty);
    }

    /**
     * @dev Create a new lock
     * @param value Total units of staked token to lockup
     * @param unlockTime Time point at which to unlock the stake
     */
    function createLock(uint256 value, uint256 unlockTime) external nonReentrant {
        LockedBalance memory Locked = LockedBalance({
            // get the users current position - 0 if new user
            amount: lockedBalances[msg.sender].amount,
            end: lockedBalances[msg.sender].end
        });

        require(value > 0, "Stake must be non-zero amount");
        require(Locked.amount == 0, "Withdraw old tokens first");

        // Floor to week
        uint endWeek = (unlockTime / WEEK) * WEEK;
        require(
            endWeek >= block.timestamp + WEEK,
            "Duration must be at least one week"
        );
        require(
            endWeek <= block.timestamp + MAXTIME,
            "Duration can be one year at most"
        );

        _depositFor(msg.sender, value, endWeek, Locked, LockAction.CREATE_LOCK);
    }

    /**
     * @dev Extend lock of msg.sender by tokens without affecting lock time 
     * @param amount Amount of tokens to add to lock
     */
    function increaseAmount(uint amount) external nonReentrant {
// get user's lock 
        LockedBalance memory Locked = lockedBalances[msg.sender];
        require(amount > 0, "Amount must be non-zero"); 
        require(Locked.amount > 0, "No lock found");
        require(Locked.end > block.timestamp, "Lock is expired, withdraw first");

        _depositFor(msg.sender, amount, 0, Locked, LockAction.INCREASE_LOCK_AMOUNT);

    }

    /**
     * @dev Extend lock of msg.sender by time without affecting lock amount 
     * @param newTime new unlock time
     */
    function increaseTime(uint newTime) external nonReentrant {
                LockedBalance memory Locked = lockedBalances[msg.sender];

        uint unlockTime = (newTime / WEEK) * WEEK;
        require(Locked.amount > 0, "No lock found");
        require(Locked.end > block.timestamp, "Lock expired, withdraw");
        require(unlockTime > Locked.end, "New time must be after old");
        require(unlockTime <= block.timestamp + MAXTIME, "Maximum locking duration four years");

        _depositFor(msg.sender, 0, unlockTime, Locked, LockAction.INCREASE_LOCK_TIME);

    }
/**
* @dev Get the balance of an account at a certain time
* @param addr Address of the account
* @param ts Time at which to get balance
* @return balance of account at time ts
 */
    function balanceOfAt(address addr, uint ts) external view returns (uint) {
        return _balanceOf(addr, ts);
    }

    /**
     * @dev Get the current balance of an account
     * @param addr Address of the account
     * @return balance of account
     */
    function currentBalance(address addr) external view returns (uint) {
        return _balanceOf(addr, block.timestamp);
    }

    /**
     * @dev Modify or create a stake for a given address
     * @param addr User address to assign the stake
     * @param value New or additional units of staking token to lockup
     * @param unlockTime New or modified timestamp at which to unlock stake
     * @param Locked Previous lock of this user
     */
    function _depositFor(
        address addr,
        uint256 value,
        uint256 unlockTime,
        LockedBalance memory Locked,
        LockAction lockedAction
    ) internal {
        require(
            ERC20(GREEN).balanceOf(addr) >= value,
            "Not enough GREEN balance"
        ); // don't need this necessarily

        // For checkpoint() we need the old and new LockedBalance, so create a copy here to update with new values
        LockedBalance memory newLocked = LockedBalance({
            amount: Locked.amount,
            end: Locked.end
        });

        // set initial value or add to old one
        newLocked.amount = newLocked.amount + SafeCast.toInt128(int256(value));
        // update the end value
        if (unlockTime != 0) {
            newLocked.end = unlockTime;
        }
        // store updated lock for user
        lockedBalances[addr] = newLocked;

        _checkpoint(addr, Locked, newLocked);

        if (value != 0) {
            ERC20(GREEN).safeTransferFrom(addr, address(this), value);
        }
        // mint veGREEN
        // _mint(_add
        emit Deposit(addr, value, newLocked.end, lockedAction, block.timestamp);
    }

    /**
     * @dev Records a checkpoint of both individual and global slope
     * @param addr User address, or address(0) for only global
     * @param oldLocked Old amount that user had locked, or null for global
     * @param newLocked new amount that user has locked, or null for global
     */
    function _checkpoint(
        address addr,
        LockedBalance memory oldLocked,
        LockedBalance memory newLocked
    ) internal {
        // hold checkpoint for user
        Point memory userOldPoint;
        Point memory userNewPoint;
        // represents change in slope at end of old/new lock
        // it can be negative when the user creates a new lock
        int128 oldSlopeDelta = 0;
        int128 newSlopeDelta = 0;
        uint256 epoch = globalEpoch;

        // calculate slopes and biases if the user modified any lock
        if (addr != address(0)) {
            // if old lock was pre-existing
            if (oldLocked.end > block.timestamp && oldLocked.amount > 0) {
                userOldPoint.slope = oldLocked.amount / iMAXTIME;
                // slope * lock time
                // represents the increase in voting power from the locked token amount and remaining duration of lock
                userOldPoint.bias =
                    userOldPoint.slope *
                    int128(int(oldLocked.end - block.timestamp));
            }
            // lock was created or extended (in value + duration)
            if (newLocked.end > block.timestamp && newLocked.amount > 0) {
                userNewPoint.slope = newLocked.amount / iMAXTIME;
                userNewPoint.bias =
                    userNewPoint.slope *
                    int128(int(newLocked.end - block.timestamp));
            }

            // get the values of scheduled changes in the slope
            oldSlopeDelta = slopeChanges[oldLocked.end];
            if (newLocked.end != 0) {
                // if the user just deposited more tokens
                if (newLocked.end == oldLocked.end) {
                    newSlopeDelta = oldSlopeDelta;
                } else {
                    // user extended or created new lock
                    newSlopeDelta = slopeChanges[newLocked.end];
                }
            }
        }

        // Now calculate global voting power

        // accumulate voting power in this struct (in later loop)
        // either a point representing current time (if epoch = 0), or last recorded checkpoint
        Point memory lastPoint = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });
        if (epoch > 0) {
            lastPoint = pointHistory[epoch];
            console.log("getting checkpoint at", epoch);
        }
        // get the time for this last checkpoint
        uint lastCheckpoint = lastPoint.ts;
        // initial_ lastPoint is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract

        // save for later approximation of the block number
        uint initialLastPointTs = lastPoint.ts;
        uint initialLastPointBlk = lastPoint.blk;

        // estimate how many blocks have been mined since last checkpoint with d(blocks)/dt
        // will be 0 if epoch = 0, or if last checkpoint was in this block
        uint blockSlope = 0;
        if (block.timestamp > lastPoint.ts) {
            blockSlope =
                (MULTIPLIER * (block.number - lastPoint.blk)) /
                (block.timestamp - lastPoint.ts);
        }

        // this is the timestamp at the end of the previous week (starting from now, or the last checkpoint)
        uint t_i = (lastCheckpoint / WEEK) * WEEK;

        // this loop iterates over weeks from the last checkpoint until now
        // it incrementally updates the global voting power for each weekly iteration and stores it as a checkpoint in the global history
        // notice there can be at most 255 loops, if the function is not used for ~5yrs, users will be able to withdraw but vote weight will be broken
        for (uint i = 0; i < 255; ++i) {
            // let time represent end of this week
            t_i += WEEK;

            // get slope delta
            int128 slopeDelta = 0;
            if (t_i > block.timestamp) {
                // if the time is in the future, reset it to current one
                t_i = block.timestamp;
            } else {
                // else slopeDelta can be made to represent the change in slope at the end of this week
                slopeDelta = slopeChanges[t_i];
            }

            // calculate accumulated voting power over the week that passed; and subtract
            // bias represents the accumulated voting power until the previous checkpoint (week)
            lastPoint.bias -=
                lastPoint.slope *
                int128(int(t_i - lastCheckpoint));

            // add the change in slope & sanity checks
            lastPoint.slope += slopeDelta;
            if (lastPoint.bias < 0) {
                // This can happen
                lastPoint.bias = 0;
            }
            if (lastPoint.slope < 0) {
                // This cannot happen - just in case
                lastPoint.slope = 0;
            }

            // set checkpoint for next loop
            lastCheckpoint = t_i;
            lastPoint.ts = t_i;
            // approximate block number for checkpoint using blockSlope
            lastPoint.blk =
                initialLastPointBlk +
                // always t_i > initialLastPointTs
                (blockSlope * (t_i - initialLastPointTs)) /
                MULTIPLIER;

            // Increase epoch
            epoch += 1;
            // if already at current time, break loop
            // if not, store checkpoint in global history and continue
            if (t_i == block.timestamp) {
                lastPoint.blk = block.number;
                break;
            } else {
                pointHistory[epoch] = lastPoint;
            }
        }
        console.log("exited with epoch", epoch);

        // update global epoch to account for the new checkpoints
        globalEpoch = epoch;

        // in case of user lock, update the global voting power with the user's new lock
        if (addr != address(0)) {
            // add the change in voting power rate of change (slope) to global history
            lastPoint.slope += (userNewPoint.slope - userOldPoint.slope);
            // add the change in accumulated voting power (bis) to global history
            lastPoint.bias += (userNewPoint.bias - userOldPoint.bias);
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
        }

        // Finally record this last checkpoint (that accounts for any user's lock) in the global history
        pointHistory[epoch] = lastPoint;

        // Lastly, in case the user changed any locks, modify the scheduled slope changes
        if (addr != address(0x0)) {
            // in the case that there was a pre-existing old lock
            if (oldLocked.end > block.timestamp) {
                // cancel the calculation from (**)
                oldSlopeDelta += userOldPoint.slope;
                // in case the user just deposited tokens, not extend the lock duration
                if (newLocked.end == oldLocked.end) {
                    // substract slope from new amount to only account for the old slope
                    oldSlopeDelta -= userNewPoint.slope;
                }
                // and schedule slope change
                slopeChanges[oldLocked.end] = oldSlopeDelta;
            }

            // in case the user is extending the lock or creating a new one
            if (newLocked.end > block.timestamp) {
                if (newLocked.end > oldLocked.end) {
                    // (**), can be negative
                    newSlopeDelta -= userNewPoint.slope;
                    slopeChanges[newLocked.end] = newSlopeDelta;
                }
                // else: we recorded it already in oldSlopeDelta
            }

            // update the values in storage for the user
            address addr_ = addr; // fix stack too deep error
            uint userEpoch = userPointEpoch[addr_] + 1;

            userPointEpoch[addr_] = userEpoch;
            userNewPoint.ts = block.timestamp;
            userNewPoint.blk = block.number;
            userPointHistory[addr_][userEpoch] = userNewPoint;
        }
    }

    /**
     * @notice Returns the current balance of a user at time ts
        * @param addr The address of the user
        * @param ts The timestamp at which to calculate the balance
        * @return The current balance of the user
        */ 
    function _balanceOf(address addr, uint ts) internal view returns (uint) {
        uint epoch = userPointEpoch[addr];
        if (epoch == 0) {
            return 0;
        } else {
            Point memory lastPoint = userPointHistory[addr][epoch];
            lastPoint.bias -=
                lastPoint.slope *
                int128(int(ts) - int(lastPoint.ts));
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            return uint(int(lastPoint.bias));
        }
    }
}
