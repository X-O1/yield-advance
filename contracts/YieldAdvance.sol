// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title YieldAdvance
 * @notice Handles logic for yield advances, debt accounting, and collateral tracking using share mechanics.
 * @dev All actual token transfers and accounting are handled by the calling protocol. This contract only manages metadata and logic for shares, debt, and protocol-specific revenue.
 * @dev All numbers and internal accounting are in RAY units (1e27)
 */
import "./YieldAdvanceErrors.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {DataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";
import {IYieldAdvance} from "./interfaces/IYieldAdvance.sol";

contract YieldAdvance is IYieldAdvance {
    using WadRayMath for uint256;
    // aave pool interface

    IPool private immutable i_pool;
    // aave address provider
    IPoolAddressesProvider public immutable i_addressesProvider;
    // RAY (1e27)
    uint256 constant RAY = 1e27;

    struct AccountBalances {
        uint256 collateralShares;
        uint256 collataral;
        uint256 debt;
        uint256 yield;
    }

    struct ProtocolBalances {
        uint256 totalCollateralShares;
        uint256 totalCollataral;
        uint256 totalDebt;
        uint256 totalYield;
        uint256 totalRevenueShares;
    }

    // account balances
    mapping(address protocol => mapping(address account => mapping(address token => AccountBalances))) public
        s_accountBalances;
    // protocol balances
    mapping(address protocol => mapping(address token => ProtocolBalances)) public s_protocolBalances;

    // sets address provider and fetches pool address
    constructor(address _addressProvider) {
        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_pool = IPool(i_addressesProvider.getPool());
    }

    /// @inheritdoc IYieldAdvance
    function getAdvance(address _account, address _token, uint256 _collateral, uint256 _advanceAmount)
        external
        returns (uint256 _advanceMinusFee)
    {
        uint256 rayCollateral = _toRay(_collateral);
        uint256 rayAdvanceAmount = _toRay(_advanceAmount);
        uint256 advanceFee = _getRayAdvanceFee(_collateral, _advanceAmount);
        uint256 advancePlusFee = rayAdvanceAmount + advanceFee;
        uint256 currentIndex = _getCurrentLiquidityIndex(_token);

        if (rayAdvanceAmount < advanceFee) revert OVERFLOW();
        uint256 advanceMinusFee = rayAdvanceAmount - advanceFee;

        uint256 collateralSharesMinted = rayCollateral.rayDiv(currentIndex);
        uint256 revenueSharesMinted = advanceFee.rayDiv(currentIndex);

        _updateGetAdvanceBalances(
            msg.sender, _account, _token, collateralSharesMinted, rayCollateral, rayAdvanceAmount, revenueSharesMinted
        );

        emit Advance_Taken(msg.sender, _account, _token, _collateral, advancePlusFee);
        return advanceMinusFee;
    }

    /// @inheritdoc IYieldAdvance
    function withdrawCollateral(address _account, address _token) external returns (uint256) {
        uint256 currentDebt = _updateAccountDebtFromYield(_account, _token);
        if (currentDebt > 0) revert REPAY_ADVANCE_TO_WITHDRAW();

        uint256 accountCollateral = s_accountBalances[msg.sender][_account][_token].collataral;
        uint256 accountShares = s_accountBalances[msg.sender][_account][_token].collateralShares;

        s_protocolBalances[msg.sender][_token].totalCollateralShares -= accountShares;
        s_accountBalances[msg.sender][_account][_token].collateralShares = 0;
        s_accountBalances[msg.sender][_account][_token].collataral = 0;

        emit Withdraw_Collateral(msg.sender, _account, _token, accountCollateral);
        return accountCollateral;
    }

    /// @inheritdoc IYieldAdvance
    function repayAdvanceWithDeposit(address _account, address _token, uint256 _amount) external returns (uint256) {
        uint256 currentDebt = _updateAccountDebtFromYield(_account, _token);

        uint256 amountRay = _toRay(_amount);
        if (currentDebt > 0 && amountRay <= currentDebt) {
            s_accountBalances[msg.sender][_account][_token].debt -= amountRay;
            s_protocolBalances[msg.sender][_token].totalDebt -= amountRay;
        }

        emit Advance_Repayment_Deposit(
            msg.sender, _account, _token, _amount, s_accountBalances[msg.sender][_account][_token].debt / 1e27
        );
        return s_accountBalances[msg.sender][_account][_token].debt;
    }

    /// @inheritdoc IYieldAdvance
    function claimRevenue(address _token) external returns (uint256) {
        uint256 numOfRevenueShares = s_protocolBalances[msg.sender][_token].totalRevenueShares;
        if (numOfRevenueShares == 0) revert NO_REVENUE_TO_CLAIM();

        s_protocolBalances[msg.sender][_token].totalRevenueShares = 0;

        emit Revenue_Claimed(msg.sender, numOfRevenueShares);
        return numOfRevenueShares;
    }

    // updates balances for getAdvance()
    function _updateGetAdvanceBalances(
        address _protocol,
        address _account,
        address _token,
        uint256 _collateralSharesMinted,
        uint256 _collateral,
        uint256 _advanceAmount,
        uint256 _revenueSharesMinted
    ) private {
        s_accountBalances[_protocol][_account][_token].collateralShares += _collateralSharesMinted;
        s_accountBalances[_protocol][_account][_token].collataral += _collateral;
        s_accountBalances[_protocol][_account][_token].debt += _advanceAmount;

        s_protocolBalances[_protocol][_token].totalCollateralShares += _collateralSharesMinted;
        s_protocolBalances[_protocol][_token].totalRevenueShares += _revenueSharesMinted;
        s_protocolBalances[_protocol][_token].totalCollataral += _collateral;
        s_protocolBalances[_protocol][_token].totalDebt += _advanceAmount;
    }

    // updates debt based on yield generated since last interaction
    function _updateAccountDebtFromYield(address _account, address _token) private returns (uint256) {
        uint256 yieldProducedByCollateral = _trackAccountYeild(msg.sender, _account, _token);
        uint256 accountDebt = s_accountBalances[msg.sender][_account][_token].debt;

        if (accountDebt > 0) {
            if (yieldProducedByCollateral >= accountDebt) {
                s_accountBalances[msg.sender][_account][_token].debt = 0;
                s_accountBalances[msg.sender][_account][_token].yield -= accountDebt;
                s_protocolBalances[msg.sender][_token].totalDebt -= accountDebt;
                s_protocolBalances[msg.sender][_token].totalYield -= accountDebt;
            } else {
                s_accountBalances[msg.sender][_account][_token].debt -= yieldProducedByCollateral;
                s_accountBalances[msg.sender][_account][_token].yield -= yieldProducedByCollateral;
                s_protocolBalances[msg.sender][_token].totalDebt -= yieldProducedByCollateral;
                s_protocolBalances[msg.sender][_token].totalYield -= yieldProducedByCollateral;
            }
        }

        return s_accountBalances[msg.sender][_account][_token].debt;
    }

    // compares share value to collateral and tracks the yield difference
    function _trackAccountYeild(address _protocol, address _account, address _token) private returns (uint256) {
        uint256 valueOfShares =
            s_accountBalances[_protocol][_account][_token].collateralShares.rayMul(_getCurrentLiquidityIndex(_token));
        uint256 valueOfCollateral = s_accountBalances[_protocol][_account][_token].collataral;
        uint256 totalYield;

        if (valueOfShares > valueOfCollateral) {
            totalYield = valueOfShares - valueOfCollateral;
            s_accountBalances[_protocol][_account][_token].yield += totalYield;
            s_protocolBalances[_protocol][_token].totalYield += totalYield;
        }

        return totalYield;
    }

    // calculates fee on advance: base 10% + linear scaling based on advance-to-collateral ratio
    function _getRayAdvanceFee(uint256 _collateral, uint256 _advanceAmount) private pure returns (uint256) {
        uint256 baseFeePercentage = 10;
        uint256 scaledFeePercentage = (_advanceAmount * 100) / _collateral;
        uint256 totalFeePercentage = baseFeePercentage + scaledFeePercentage;
        uint256 finalFee = (_advanceAmount * totalFeePercentage) / 100;
        return _toRay(finalFee);
    }

    // gets current liquidity index from Aave
    function _getCurrentLiquidityIndex(address _token) private view returns (uint256) {
        uint256 currentIndex = uint256(i_pool.getReserveData(_token).liquidityIndex);
        if (currentIndex < 1e27) revert INVALID_LIQUIDITY_INDEX();
        return currentIndex;
    }

    // converts number to RAY (1e27) units
    function _toRay(uint256 _num) private pure returns (uint256) {
        return _num * 1e27;
    }

    /// @inheritdoc IYieldAdvance
    function getShareValue(address _token, uint256 _shares) external view returns (uint256) {
        return _shares.rayMul(_getCurrentLiquidityIndex(_token));
    }

    /// @inheritdoc IYieldAdvance
    function getCollateralShares(address _account, address _token) external view returns (uint256) {
        return s_accountBalances[msg.sender][_account][_token].collateralShares;
    }

    /// @inheritdoc IYieldAdvance
    function getAccountTotalYield(address _account, address _token) external returns (uint256) {
        return _trackAccountYeild(msg.sender, _account, _token);
    }

    /// @inheritdoc IYieldAdvance
    function getDebt(address _account, address _token) external returns (uint256) {
        return _updateAccountDebtFromYield(_account, _token);
    }

    /// @inheritdoc IYieldAdvance
    function getAccountTotalShareValue(address _account, address _token) external view returns (uint256) {
        return
            s_accountBalances[msg.sender][_account][_token].collateralShares.rayMul(_getCurrentLiquidityIndex(_token));
    }

    /// @inheritdoc IYieldAdvance
    function getCollateralAmount(address _account, address _token) external view returns (uint256) {
        return s_accountBalances[msg.sender][_account][_token].collataral;
    }

    /// @inheritdoc IYieldAdvance
    function getTotalDebt(address _token) external view returns (uint256) {
        return s_protocolBalances[msg.sender][_token].totalDebt;
    }

    /// @inheritdoc IYieldAdvance
    function getTotalRevenueShares(address _token) external view returns (uint256) {
        return s_protocolBalances[msg.sender][_token].totalRevenueShares;
    }

    /// @inheritdoc IYieldAdvance
    function getTotalRevenueShareValue(address _token) external view returns (uint256) {
        return s_protocolBalances[msg.sender][_token].totalRevenueShares.rayMul(_getCurrentLiquidityIndex(_token));
    }

    /// @inheritdoc IYieldAdvance
    function getYieldAdvanceContractAddress() external view returns (address) {
        return address(this);
    }
}
