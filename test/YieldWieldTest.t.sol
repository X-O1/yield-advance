// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldWield} from "../src/YieldWield.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IERC20} from "@openzeppelin/ERC20/IERC20.sol";

/**
 * @title Test for YieldWield.sol on the BASE Mainnet
 * @notice All addresses are for Base Mainnet
 */
contract YieldWieldTest is Test {
    YieldWield yieldWield;
    address yieldWieldAddress;
    address protocol = 0x7Cc00Dc8B6c0aC2200b989367E30D91B7C7F5F43;
    address user = 0x7e6Af92Df2aEcD6113325c0b58F821ab1dCe37F6;
    address usdcAddress = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address aUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address addressProvider = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    address poolAddress = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    uint256 baseMainnetChainID = 8453;

    function setUp() external {
        if (block.chainid == baseMainnetChainID) {
            yieldWield = new YieldWield(addressProvider);
            yieldWieldAddress = yieldWield.getYieldWieldContractAddress();

            vm.prank(protocol);
            IERC20(usdcAddress).approve(poolAddress, type(uint256).max);
        }
    }

    modifier ifBaseMainnet() {
        if (block.chainid == baseMainnetChainID) {
            _;
        }
    }

    function testGetAdvanceAccounting() public ifBaseMainnet {
        vm.prank(protocol);
        assertEq(yieldWield.getAdvance(user, usdcAddress, 1000, 100), 80);
        vm.prank(protocol);
        assertEq(yieldWield.getCollateralAmount(user, usdcAddress), 1000);
        vm.prank(protocol);
        assertEq(yieldWield.getDebt(user, usdcAddress), 100);
        vm.prank(protocol);
        assertEq(yieldWield.getTotalRevenueShareValue(usdcAddress), 20);
    }

    function testRepayingAdvanceWithDepositAccounting() public ifBaseMainnet {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        yieldWield.repayAdvanceWithDeposit(user, usdcAddress, 50);
        vm.prank(protocol);
        assertEq(yieldWield.getDebt(user, usdcAddress), 50);
    }

    function testYieldRepayingDebtOverTime() public ifBaseMainnet {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        assertEq(yieldWield.getDebt(user, usdcAddress), 100);
        vm.prank(protocol);
        console.logUint(yieldWield.getDebt(user, usdcAddress));

        vm.prank(protocol);
        IPool(poolAddress).supply(usdcAddress, 1, msg.sender, 0);

        vm.warp(block.timestamp + 365 days);

        vm.prank(protocol);
        IPool(poolAddress).supply(usdcAddress, 1, msg.sender, 0);

        vm.prank(protocol);
        yieldWield.getAndupdateAccountDebtFromYield(user, usdcAddress);
        vm.prank(protocol);
        console.logUint(yieldWield.getDebt(user, usdcAddress));
    }

    function testWithdrawingCollateralAccounting() public ifBaseMainnet {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 100);

        vm.prank(protocol);
        vm.expectRevert();
        yieldWield.withdrawCollateral(user, usdcAddress);

        vm.prank(protocol);
        yieldWield.repayAdvanceWithDeposit(user, usdcAddress, 100);

        vm.prank(protocol);
        yieldWield.withdrawCollateral(user, usdcAddress);

        vm.prank(protocol);
        assertEq(yieldWield.getCollateralShares(user, usdcAddress), 0);
        vm.prank(protocol);
        assertEq(yieldWield.getCollateralAmount(user, usdcAddress), 0);
    }

    function testClaimRevenueAccounting() public ifBaseMainnet {
        vm.prank(protocol);
        assertEq(yieldWield.getAdvance(user, usdcAddress, 1000, 100), 80);
        vm.prank(protocol);
        assertEq(yieldWield.getTotalRevenueShareValue(usdcAddress), 20);

        vm.prank(protocol);
        yieldWield.claimRevenue(usdcAddress);
        vm.prank(protocol);
        assertEq(yieldWield.getTotalRevenueShareValue(usdcAddress), 0);
    }

    function testGetCollateralShares() public ifBaseMainnet {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        uint256 shares = yieldWield.getCollateralShares(user, usdcAddress);
        assertGt(shares, 0);
    }

    function testGetAccountTotalYield() public ifBaseMainnet {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 100);

        vm.prank(protocol);
        IPool(poolAddress).supply(usdcAddress, 1, msg.sender, 0);

        vm.warp(block.timestamp + 365 days);

        vm.prank(protocol);
        IPool(poolAddress).supply(usdcAddress, 1, msg.sender, 0);

        vm.prank(protocol);
        yieldWield.getAndupdateAccountDebtFromYield(user, usdcAddress);

        vm.prank(protocol);
        uint256 yieldAmount = yieldWield.getAccountTotalYield(user, usdcAddress);
        console.logUint(yieldAmount);
        assertGt(yieldAmount, 0);
    }

    function testGetTotalDebt() public ifBaseMainnet {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 200);
        vm.prank(protocol);
        uint256 totalDebt = yieldWield.getTotalDebt(usdcAddress);
        assertEq(totalDebt, 200);
    }

    function testGetTotalRevenueShares() public ifBaseMainnet {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 200);
        vm.prank(protocol);
        uint256 totalRevShares = yieldWield.getTotalRevenueShares(usdcAddress);
        assertGt(totalRevShares, 0);
    }

    function testGetYieldWieldContractAddress() public view ifBaseMainnet {
        address addr = yieldWield.getYieldWieldContractAddress();
        assertEq(addr, address(yieldWield));
    }

    function testGetDebt() public ifBaseMainnet {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 200);
        vm.prank(protocol);
        uint256 debt = yieldWield.getDebt(user, usdcAddress);
        assertEq(debt, 200);
    }
}
