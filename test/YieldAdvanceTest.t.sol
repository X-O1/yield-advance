// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldAdvance} from "../contracts/YieldAdvance.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAUSDC} from "./mocks/MockAUSDC.sol";

/**
 * @title Test for YieldAdvance.sol with mock aave
 */
contract YieldAdvanceMainnetTest is Test {
    YieldAdvance yieldAdvance;
    MockPool mockPool;
    MockUSDC usdc;
    MockAUSDC aUSDC;
    address protocol = makeAddr("protocol");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
    address yieldAdvanceAddress;
    address usdcAddress;
    address aUSDCAddress;
    address addressProvider;
    uint256 RAY = 1e27;

    function setUp() external {
        usdc = new MockUSDC();
        usdc.mint(protocol, 1000);
        usdc.mint(user, 1000);
        usdc.mint(user2, 1000);
        usdcAddress = usdc.getAddress();
        aUSDC = new MockAUSDC();
        aUSDCAddress = aUSDC.getAddress();
        mockPool = new MockPool(usdcAddress, aUSDCAddress);
        addressProvider = mockPool.getPool();
        yieldAdvance = new YieldAdvance(addressProvider);
        yieldAdvanceAddress = yieldAdvance.getYieldAdvanceContractAddress();
        vm.prank(protocol);
        usdc.approve(addressProvider, type(uint256).max);
    }

    function testGetAdvanceAccounting() public {
        vm.prank(protocol);
        assertEq(yieldAdvance.getAdvance(user, usdcAddress, 100, 20), 14 * RAY);
        vm.prank(protocol);
        assertEq(yieldAdvance.getTotalRevenueShareValue(usdcAddress), 6 * RAY);
        vm.prank(protocol);
        assertEq(yieldAdvance.getCollateralAmount(user, usdcAddress), 100 * RAY);
        vm.prank(protocol);
        assertEq(yieldAdvance.getAccountTotalShareValue(user, usdcAddress), 100 * RAY);
        vm.prank(protocol);
        assertEq(yieldAdvance.getDebt(user, usdcAddress), 20 * RAY);
    }

    function testRepayingAdvanceWithDepositAccounting() public {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        yieldAdvance.repayAdvanceWithDeposit(user, usdcAddress, 50);
        vm.prank(protocol);
        assertEq(yieldAdvance.getDebt(user, usdcAddress), 50 * RAY);
    }

    function testYieldRepayingDebtOverTime() public {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        assertEq(yieldAdvance.getDebt(user, usdcAddress), 100 * RAY);
        vm.prank(protocol);
        mockPool.setLiquidityIndex(address(usdc), 2e27);
        vm.prank(protocol);
        assertEq(yieldAdvance.getDebt(user, usdcAddress), 0);
        vm.prank(protocol);
        assertEq(yieldAdvance.getAccountTotalYield(user, usdcAddress), 1000 * RAY);
        vm.prank(protocol);
        mockPool.setLiquidityIndex(address(usdc), 1e27);
        vm.prank(protocol);
        yieldAdvance.getAdvance(user2, usdcAddress, 1000, 100);
        vm.prank(protocol);
        assertEq(yieldAdvance.getDebt(user2, usdcAddress), 100 * RAY);
        vm.prank(protocol);
        mockPool.setLiquidityIndex(address(usdc), 105e25);
        vm.prank(protocol);
        assertEq(yieldAdvance.getDebt(user2, usdcAddress), 50 * RAY);
        vm.prank(protocol);
        assertEq(yieldAdvance.getAccountTotalYield(user2, usdcAddress), 50 * RAY);
    }

    function testWithdrawingCollateralAccounting() public {
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

    function testClaimRevenueAccounting() public {
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

    function testGetCollateralShares() public {
        vm.prank(protocol);
        mockPool.setLiquidityIndex(address(usdc), 102e25);
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        assertApproxEqAbs(yieldAdvance.getCollateralShares(user, usdcAddress), 980 * RAY, 5e26);
    }

    function testGetAccountTotalYield() public {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        mockPool.setLiquidityIndex(address(usdc), 2e27);
        vm.prank(protocol);
        assertEq(yieldAdvance.getDebt(user, usdcAddress), 0);
        vm.prank(protocol);
        assertEq(yieldAdvance.getAccountTotalYield(user, usdcAddress), 1000 * RAY);
    }

    function testGetTotalDebt() public {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 200);
        vm.prank(protocol);
        assertEq(yieldAdvance.getTotalDebt(usdcAddress), 200 * RAY);
    }

    function testGetTotalRevenueShares() public {
        vm.prank(protocol);
        yieldAdvance.getAdvance(user, usdcAddress, 1000, 200);
        vm.prank(protocol);
        assertEq(yieldAdvance.getTotalRevenueShares(usdcAddress), 60 * RAY);
    }

    function testGetYieldAdvanceContractAddress() public view {
        assertEq(yieldAdvance.getYieldAdvanceContractAddress(), address(yieldAdvance));
    }
}
