// SPDX-License-Identifier: UNLICENSED
pragma solidity >0.8.0;

import {ERC20} from "@openzeppelin-contracts/ERC20.sol";
import {IERC20} from "@openzeppelin-contracts/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/SafeERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/SafeCast.sol";
import {Ownable} from "@openzeppelin-contracts/Ownable.sol";

/**
 * @title VotingEscrow
 * @dev VotingEscrow is a non standard ERC20token $veGREEN used to represent the voting power of a user. Users lock $GREEN to obtain $veGREEN. Voting power decreases linearly from the moment of locking.
 * Based on https://github.com/curvefi/curve-dao-contracts/blob/master/doc/README.md
 * Voting weight is equal to w = amount *  t / t_max , so it is dependent on both the locked amount as well as the time locked.
 *
 */
contract VotingEscrow is ERC20, Ownable {
    using SafeERC20 for ERC20;

    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 locktime,
        LockAction indexed action,
        uint256 ts
    );

    // Shared global state
    address public immutable GREEN;
    uint256 public constant WEEK = 1 weeks;
    // Maximum lock time is 4 years
    uint256 public constant MAXTIME = 4 * 52 * WEEK;
    // safe cast to uint
    int128 internal constant iMAXTIME = int(MAXTIME);

    // address public blocklist
    // Smart contract addresses which are allowed to deposit
    // One wants to prevent the veGREEN from being tokenized
    mapping(address => bool) public whitelist;

    // Lock state
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
        CREATE_LOCK
        // INCREASE_LOCK_AMOUNT,
        // INCREASE_LOCK_TIME
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
     * @param unlockTime Duration in seconds after which to unlock the stake
     */
    function createLock(uint256 value, uint256 unlockTime) external {
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
}
