// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldWield} from "../../src/YieldWield.sol";
import {IERC20} from "@openzeppelin/ERC20/IERC20.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";

/**
 * @title Test for YieldWield.sol on the BASE Mainnet
 * @notice All addresses are for Base Mainnet
 */
contract YieldAdaptertTest is Test {
    YieldWield yieldWield;

    function setUp() external {
        yieldWield = new YieldWield();
    }

    function test() public {}
}
