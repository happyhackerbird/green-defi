//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {VotingEscrow} from "contracts/protocol/governance/VotingEscrow.sol";
import {ERC20} from "contracts/dependencies/openzeppelin/contracts/ERC20.sol";

contract VotingEscrowTest is Test {
    ERC20 token;
    VotingEscrow ve;

    function setUp() public {
        token = new ERC20("Green", "GRN");
        ve = new VotingEscrow(address(token));
    }

    function test_createLock() external {
        // deposit funds into user account
        // approve funds by user
        // user calls createLock
    }
}
