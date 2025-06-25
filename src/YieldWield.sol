// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title YieldWield
 * @notice Handles logic for yield advances, debt accounting, and collateral tracking using share mechanics.
 * @dev All actual token transfers and accounting are handled by the calling protocol. This contract only manages metadata and logic for shares, debt, and protocol-specific revenue.
 * @dev All numbers are in RAY units (1e27), unless otherwise stated.
 */
import "./YieldWieldErrors.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {DataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";
import {IYieldWield} from "./interfaces/IYieldWield.sol";

contract YieldWield is IYieldWield {
    using WadRayMath for uint256;

    // aave pool interface
    IPool private immutable i_pool;

    // aave address provider
    IPoolAddressesProvider public immutable i_addressesProvider;

    // user collateral shares (protocol => account => token => shares)
    mapping(address => mapping(address => mapping(address => uint256))) public s_collateralShares;

    // total collateral shares per token (protocol => token => shares)
    mapping(address => mapping(address => uint256)) public s_totalCollateralShares;

    // user raw collateral amount (protocol => account => token => ray amount)
    mapping(address => mapping(address => mapping(address => uint256))) public s_collateral;

    // total collateral per token (protocol => token => ray amount)
    mapping(address => mapping(address => uint256)) public s_totalCollateral;

    // user debt in ray (protocol => account => token => ray debt)
    mapping(address => mapping(address => mapping(address => uint256))) public s_debt;

    // uotal debt in ray (protocol => token => ray debt)
    mapping(address => mapping(address => uint256)) public s_totalDebt;

    // uield produced by an account (protocol => account => token => ray yield)
    mapping(address => mapping(address => mapping(address => uint256))) public s_accountYield;

    // total yield per token (protocol => token => ray yield)
    mapping(address => mapping(address => uint256)) public s_totalAccountYield;

    // revenue shares (protocol => token => shares)
    mapping(address => mapping(address => uint256)) public s_totalRevenueShares;

    // emitted when protocol claims revenue
    event Revenue_Claimed(address indexed protocol, uint256 revAmount);

    // sets address provider and resolves pool address
    constructor(address _addressProvider) {
        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_pool = IPool(i_addressesProvider.getPool());
    }

    /// @inheritdoc IYieldWield
    function getAdvance(address _account, address _token, uint256 _collateral, uint256 _advanceAmount)
        external
        returns (uint256 _advanceMinusFee)
    {
        address protocol = msg.sender;
        uint256 advanceFee = _getAdvanceFee(_collateral, _advanceAmount);
        uint256 advancePlusFee = _advanceAmount + advanceFee;
        uint256 advanceMinusFee = _advanceAmount - advanceFee;

        uint256 collateralSharesMinted = _toRay(_collateral).rayDiv(_getCurrentLiquidityIndex(_token));
        uint256 revenueSharesMinted = _toRay(advanceFee).rayDiv(_getCurrentLiquidityIndex(_token));

        s_collateralShares[protocol][_account][_token] += collateralSharesMinted;
        s_collateral[protocol][_account][_token] += _toRay(_collateral);
        s_debt[protocol][_account][_token] += _toRay(_advanceAmount);

        s_totalCollateralShares[protocol][_token] += collateralSharesMinted;
        s_totalRevenueShares[protocol][_token] += revenueSharesMinted;
        s_totalCollateral[protocol][_token] += _toRay(_collateral);
        s_totalDebt[protocol][_token] += _toRay(_advanceAmount);

        emit Advance_Taken(protocol, _account, _token, _collateral, advancePlusFee);
        return advanceMinusFee;
    }

    /// @inheritdoc IYieldWield
    function withdrawCollateral(address _account, address _token) external returns (uint256) {
        address protocol = msg.sender;
        uint256 currentDebt = _updateAccountDebtFromYield(_account, _token);
        if (currentDebt > 0) revert REPAY_ADVANCE_TO_WITHDRAW();

        uint256 accountCollateral = s_collateral[protocol][_account][_token] / 1e27;
        uint256 accountShares = s_collateralShares[protocol][_account][_token];

        s_totalCollateralShares[protocol][_token] -= accountShares;
        s_collateralShares[protocol][_account][_token] = 0;
        s_collateral[protocol][_account][_token] = 0;

        emit Withdraw_Collateral(protocol, _account, _token, accountCollateral);
        return accountCollateral;
    }

    /// @inheritdoc IYieldWield
    function repayAdvanceWithDeposit(address _account, address _token, uint256 _amount) external returns (uint256) {
        address protocol = msg.sender;
        uint256 currentDebt = _updateAccountDebtFromYield(_account, _token);

        uint256 amountRay = _toRay(_amount);
        if (currentDebt > 0 && amountRay <= currentDebt) {
            s_debt[protocol][_account][_token] -= amountRay;
            s_totalDebt[protocol][_token] -= amountRay;
        }

        emit Advance_Repayment_Deposit(protocol, _account, _token, _amount, s_debt[protocol][_account][_token] / 1e27);
        return s_debt[protocol][_account][_token];
    }

    /// @inheritdoc IYieldWield
    function claimRevenue(address _token) external returns (uint256) {
        address protocol = msg.sender;
        uint256 numOfRevenueShares = s_totalRevenueShares[protocol][_token];
        if (numOfRevenueShares == 0) revert NO_REVENUE_TO_CLAIM();

        uint256 newRevShares = _convertAmountToShares(_token, numOfRevenueShares);
        s_totalRevenueShares[protocol][_token] = 0;

        emit Revenue_Claimed(protocol, newRevShares);
        return newRevShares;
    }

    // updates debt based on yield generated since last interaction
    function _updateAccountDebtFromYield(address _account, address _token) private returns (uint256) {
        address protocol = msg.sender;
        uint256 yieldProducedByCollateral = _trackAccountYeild(protocol, _account, _token);
        uint256 accountDebt = s_debt[protocol][_account][_token];

        if (accountDebt > 0) {
            if (yieldProducedByCollateral >= accountDebt) {
                s_debt[protocol][_account][_token] = 0;
                s_totalDebt[protocol][_token] -= accountDebt;
                s_accountYield[protocol][_account][_token] -= accountDebt;
                s_totalAccountYield[protocol][_token] -= accountDebt;
            } else {
                s_debt[protocol][_account][_token] -= yieldProducedByCollateral;
                s_totalDebt[protocol][_token] -= yieldProducedByCollateral;
                s_accountYield[protocol][_account][_token] -= yieldProducedByCollateral;
                s_totalAccountYield[protocol][_token] -= yieldProducedByCollateral;
            }
        }

        return s_debt[protocol][_account][_token];
    }

    // compares share value to raw collateral and tracks the yield difference
    function _trackAccountYeild(address _protocol, address _account, address _token) private returns (uint256) {
        uint256 valueOfShares =
            s_collateralShares[msg.sender][_account][_token].rayMul(_getCurrentLiquidityIndex(_token));
        uint256 valueOfCollateral = s_collateral[msg.sender][_account][_token];
        uint256 totalYield;

        if (valueOfShares > valueOfCollateral) {
            totalYield = valueOfShares - valueOfCollateral;
            s_accountYield[_protocol][_account][_token] += totalYield;
            s_totalAccountYield[_protocol][_token] += totalYield;
        }

        return totalYield;
    }

    // calculates fee on advance (base 10% + linear scaling)
    function _getAdvanceFee(uint256 _collateral, uint256 _advanceAmount) private pure returns (uint256) {
        uint256 baseFeePercentage = 10;
        uint256 scaledFeePercentage = (_advanceAmount * 100) / _collateral;
        uint256 totalFeePercentage = baseFeePercentage + scaledFeePercentage;
        return (_advanceAmount * totalFeePercentage) / 100;
    }

    // gets current liquidity index from Aave
    function _getCurrentLiquidityIndex(address _token) private view returns (uint256) {
        uint256 currentIndex = uint256(i_pool.getReserveData(_token).liquidityIndex);
        if (currentIndex < 1e27) revert INVALID_LIQUIDITY_INDEX();
        return currentIndex;
    }

    // converts base amount to Aave share amount
    function _convertAmountToShares(address _token, uint256 _amount) private view returns (uint256) {
        uint256 index = _getCurrentLiquidityIndex(_token);
        uint256 numerator = _amount * 1e27 + index / 2;
        return numerator / index;
    }

    // converts number to ray format
    function _toRay(uint256 _number) private pure returns (uint256) {
        return _number * 1e27;
    }

    // returns share value in base units
    function getShareValue(address _token, uint256 _shares) external view returns (uint256) {
        return _shares.rayMul(_getCurrentLiquidityIndex(_token));
    }

    // returns user collateral shares
    function getCollateralShares(address _account, address _token) external view returns (uint256) {
        return s_collateralShares[msg.sender][_account][_token];
    }

    // Returns yield for account since last update
    function getAccountTotalYield(address _account, address _token) external returns (uint256) {
        return _trackAccountYeild(msg.sender, _account, _token);
    }

    // Returns updated debt value
    function getDebt(address _account, address _token) external returns (uint256) {
        return _updateAccountDebtFromYield(_account, _token);
    }

    // returns total value of account’s shares
    function getAccountTotalShareValue(address _account, address _token) external view returns (uint256) {
        return s_collateralShares[msg.sender][_account][_token].rayMul(_getCurrentLiquidityIndex(_token));
    }

    // returns raw collateral (in ray)
    function getCollateralAmount(address _account, address _token) external view returns (uint256) {
        return s_collateral[msg.sender][_account][_token];
    }

    // total debt (in ray)
    function getTotalDebt(address _token) external view returns (uint256) {
        return s_totalDebt[msg.sender][_token];
    }

    // revenue shares in ray
    function getTotalRevenueShares(address _token) external view returns (uint256) {
        return s_totalRevenueShares[msg.sender][_token];
    }

    // revenue share value in base units
    function getTotalRevenueShareValue(address _token) external view returns (uint256) {
        return s_totalRevenueShares[msg.sender][_token].rayMul(_getCurrentLiquidityIndex(_token));
    }

    // returns address of this contract
    function getYieldWieldContractAddress() external view returns (address) {
        return address(this);
    }
}
