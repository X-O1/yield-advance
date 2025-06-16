// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldWield} from "../../src/YieldWield.sol";

contract YieldWieldTest is Test {
    YieldWield yieldWield;

    function setUp() external {
        yieldWield = new YieldWield();
    }

    function test() public {}
}
