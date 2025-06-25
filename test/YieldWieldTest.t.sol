// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldWield} from "../src/YieldWield.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAUSDC} from "./mocks/MockAUSDC.sol";

/**
 * @title Test for YieldWield.sol with mock aave
 */
contract YieldWieldMainnetTest is Test {
    YieldWield yieldWield;
    MockPool mockPool;
    MockUSDC usdc;
    MockAUSDC aUSDC;
    address protocol = makeAddr("protocol");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
    address yieldWieldAddress;
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
        yieldWield = new YieldWield(addressProvider);
        yieldWieldAddress = yieldWield.getYieldWieldContractAddress();
        vm.prank(protocol);
        usdc.approve(addressProvider, type(uint256).max);
    }

    function testGetAdvanceAccounting() public {
        vm.prank(protocol);
        assertEq(yieldWield.getAdvance(user, usdcAddress, 100, 20), 14 * RAY);
        vm.prank(protocol);
        assertEq(yieldWield.getTotalRevenueShareValue(usdcAddress), 6 * RAY);
        vm.prank(protocol);
        assertEq(yieldWield.getCollateralAmount(user, usdcAddress), 100 * RAY);
        vm.prank(protocol);
        assertEq(yieldWield.getAccountTotalShareValue(user, usdcAddress), 100 * RAY);
        vm.prank(protocol);
        assertEq(yieldWield.getDebt(user, usdcAddress), 20 * RAY);
    }

    function testRepayingAdvanceWithDepositAccounting() public {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        yieldWield.repayAdvanceWithDeposit(user, usdcAddress, 50);
        vm.prank(protocol);
        assertEq(yieldWield.getDebt(user, usdcAddress), 50 * RAY);
    }

    function testYieldRepayingDebtOverTime() public {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        assertEq(yieldWield.getDebt(user, usdcAddress), 100 * RAY);
        vm.prank(protocol);
        mockPool.setLiquidityIndex(address(usdc), 2e27);
        vm.prank(protocol);
        assertEq(yieldWield.getDebt(user, usdcAddress), 0);
        vm.prank(protocol);
        assertEq(yieldWield.getAccountTotalYield(user, usdcAddress), 1000 * RAY);
        vm.prank(protocol);
        mockPool.setLiquidityIndex(address(usdc), 1e27);
        vm.prank(protocol);
        yieldWield.getAdvance(user2, usdcAddress, 1000, 100);
        vm.prank(protocol);
        assertEq(yieldWield.getDebt(user2, usdcAddress), 100 * RAY);
        vm.prank(protocol);
        mockPool.setLiquidityIndex(address(usdc), 105e25);
        vm.prank(protocol);
        assertEq(yieldWield.getDebt(user2, usdcAddress), 50 * RAY);
        vm.prank(protocol);
        assertEq(yieldWield.getAccountTotalYield(user2, usdcAddress), 50 * RAY);
    }

    function testWithdrawingCollateralAccounting() public {
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

    function testClaimRevenueAccounting() public {
        vm.prank(protocol);
        assertEq(yieldWield.getAdvance(user, usdcAddress, 1000, 100), 80 * RAY);
        vm.prank(protocol);
        assertEq(yieldWield.getTotalRevenueShareValue(usdcAddress), 20 * RAY);
        vm.prank(protocol);
        assertEq(yieldWield.claimRevenue(usdcAddress), 20 * RAY);
        vm.prank(protocol);
        assertEq(yieldWield.getTotalRevenueShareValue(usdcAddress), 0);
    }

    function testGetCollateralShares() public {
        vm.prank(protocol);
        mockPool.setLiquidityIndex(address(usdc), 102e25);
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        assertApproxEqAbs(yieldWield.getCollateralShares(user, usdcAddress), 980 * RAY, 5e26);
    }

    function testGetAccountTotalYield() public {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 100);
        vm.prank(protocol);
        mockPool.setLiquidityIndex(address(usdc), 2e27);
        vm.prank(protocol);
        assertEq(yieldWield.getDebt(user, usdcAddress), 0);
        vm.prank(protocol);
        assertEq(yieldWield.getAccountTotalYield(user, usdcAddress), 1000 * RAY);
    }

    function testGetTotalDebt() public {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 200);
        vm.prank(protocol);
        assertEq(yieldWield.getTotalDebt(usdcAddress), 200 * RAY);
    }

    function testGetTotalRevenueShares() public {
        vm.prank(protocol);
        yieldWield.getAdvance(user, usdcAddress, 1000, 200);
        vm.prank(protocol);
        assertEq(yieldWield.getTotalRevenueShares(usdcAddress), 60 * RAY);
    }

    function testGetYieldWieldContractAddress() public view {
        assertEq(yieldWield.getYieldWieldContractAddress(), address(yieldWield));
    }
}
