// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldAdvance} from "../contracts/YieldAdvance.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/**
 * @title Test for YieldAdvance.sol on the BASE Mainnet
 * @notice All addresses are for Base Mainnet
 */
contract YieldAdvanceMainnetTest is Test {
    YieldAdvance yieldAdvance;
    address yieldAdvanceAddress;
    address protocol = 0x7Cc00Dc8B6c0aC2200b989367E30D91B7C7F5F43;
    address user = 0x7e6Af92Df2aEcD6113325c0b58F821ab1dCe37F6;
    address usdcAddress = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address aUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address addressProvider = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    address poolAddress = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    uint256 baseMainnetChainID = 8453;
    uint256 RAY = 1e27;

    function setUp() external {
        if (block.chainid == baseMainnetChainID) {
            yieldAdvance = new YieldAdvance(addressProvider);
            yieldAdvanceAddress = yieldAdvance.getYieldAdvanceContractAddress();

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
        assertEq(yieldAdvance.getAdvance(user, usdcAddress, 100, 20), 14 * RAY);
        vm.prank(protocol);
        console.logUint(yieldAdvance.getTotalRevenueShares(usdcAddress));
        vm.prank(protocol);
        assertEq(yieldAdvance.getTotalRevenueShareValue(usdcAddress), 6 * RAY);
        vm.prank(protocol);
        assertEq(yieldAdvance.getCollateralAmount(user, usdcAddress), 100 * RAY);
        vm.prank(protocol);
        assertEq(yieldAdvance.getAccountTotalShareValue(user, usdcAddress), 100 * RAY);
        vm.prank(protocol);
        assertApproxEqAbs(yieldAdvance.getDebt(user, usdcAddress), 20 * RAY, 2);
    }

    function testRepayingAdvanceWithDepositAccounting() public ifBaseMainnet {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        yieldAdvance.repayAdvanceWithDeposit(user, usdcAddress, 50);
        vm.prank(protocol);
        assertApproxEqAbs(yieldAdvance.getDebt(user, usdcAddress), 50 * RAY, 2);
    }

    function testYieldRepayingDebtOverTime() public ifBaseMainnet {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        assertApproxEqAbs(yieldAdvance.getDebt(user, usdcAddress), 100 * RAY, 2);

        vm.prank(protocol);
        console.logUint(yieldAdvance.getDebt(user, usdcAddress));

        vm.prank(protocol);
        IPool(poolAddress).supply(usdcAddress, 1, msg.sender, 0);

        vm.warp(block.timestamp + 365 days);

        vm.prank(protocol);
        IPool(poolAddress).supply(usdcAddress, 1, msg.sender, 0);

        vm.prank(protocol);
        console.logUint(yieldAdvance.getDebt(user, usdcAddress));
    }

    function testWithdrawingCollateralAccounting() public ifBaseMainnet {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 100);

        vm.prank(protocol);
        vm.expectRevert();
        yieldAdvance.withdrawCollateral(user, usdcAddress);

        vm.prank(protocol);
        yieldAdvance.repayAdvanceWithDeposit(user, usdcAddress, 100);

        vm.prank(protocol);
        yieldAdvance.withdrawCollateral(user, usdcAddress);

        vm.prank(protocol);
        assertEq(yieldAdvance.getCollateralShares(user, usdcAddress), 0);
        vm.prank(protocol);
        assertEq(yieldAdvance.getCollateralAmount(user, usdcAddress), 0);
    }

    function testClaimRevenueAccounting() public ifBaseMainnet {
        vm.prank(protocol);
        assertEq(yieldAdvance.getAdvance(user, usdcAddress, 1000, 100), 80 * RAY);
        vm.prank(protocol);
        assertEq(yieldAdvance.getTotalRevenueShareValue(usdcAddress), 20 * RAY);
        vm.prank(protocol);
        uint256 amountOfRevShares = yieldAdvance.getTotalRevenueShares(usdcAddress);
        vm.prank(protocol);
        assertEq(yieldAdvance.claimRevenue(usdcAddress), amountOfRevShares);
        vm.prank(protocol);
        assertEq(yieldAdvance.getTotalRevenueShareValue(usdcAddress), 0);
    }

    function testGetCollateralShares() public ifBaseMainnet {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        uint256 shares = yieldAdvance.getCollateralShares(user, usdcAddress);
        assertGt(shares, 0);
    }

    function testGetAccountTotalYield() public ifBaseMainnet {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 100);

        vm.prank(protocol);
        IPool(poolAddress).supply(usdcAddress, 1, msg.sender, 0);

        vm.warp(block.timestamp + 365 days);

        vm.prank(protocol);
        IPool(poolAddress).supply(usdcAddress, 1, msg.sender, 0);

        vm.prank(protocol);
        console.logUint(yieldAdvance.getAccountTotalYield(user, usdcAddress));
    }

    function testGetTotalDebt() public ifBaseMainnet {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 200);
        vm.prank(protocol);
        uint256 totalDebt = yieldAdvance.getTotalDebt(usdcAddress);
        assertEq(totalDebt, 200 * RAY);
    }

    function testGetTotalRevenueShares() public ifBaseMainnet {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 200);
        vm.prank(protocol);
        uint256 totalRevShares = yieldAdvance.getTotalRevenueShares(usdcAddress);
        assertGt(totalRevShares, 0);
    }

    function testGetYieldAdvanceContractAddress() public view ifBaseMainnet {
        address addr = yieldAdvance.getYieldAdvanceContractAddress();
        assertEq(addr, address(yieldAdvance));
    }

    function testGetDebt() public ifBaseMainnet {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 200);
        vm.prank(protocol);
        assertApproxEqAbs(yieldAdvance.getDebt(user, usdcAddress), 200 * RAY, 2);
    }
}
