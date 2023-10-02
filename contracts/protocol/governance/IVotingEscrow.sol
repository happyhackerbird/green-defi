// SPDX-License-Identifier: UNLICENSED
pragma solidity >0.8.0;

interface IVotingEscrow {
    enum LockAction {
        CREATE_LOCK,
        INCREASE_LOCK_AMOUNT,
        INCREASE_LOCK_TIME
    }

    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 unlockTime,
        LockAction indexed action,
        uint256 ts
    );

    event Withdraw(address indexed provider, uint value, uint ts);

    function addToAllowlist(address addr) external;

    function removeFromAllowlist(address addr) external;

    function getLastUserPoint(
        address addr
    ) external returns (int128 bias, int128 slope, uint256 ts);

    function createLock(uint256 value, uint256 unlockTime) external;

    function increaseAmount(uint amount) external;

    function increaseTime(uint newTime) external;

    function checkpoint() external;

    function balanceOfAt(address addr, uint ts) external returns (uint);

    function balanceOf(address addr) external returns (uint);

    function withdraw() external;
}
