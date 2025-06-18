// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./YieldWieldErrors.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {DataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";

contract YieldWield {
    IPool private immutable i_pool;
    IPoolAddressesProvider public immutable i_addressesProvider;

    mapping(address protocol => mapping(address account => mapping(address token => uint256 shares))) public
        s_collateralShares;
    mapping(address protocol => mapping(address tokend => uint256 totalShares)) public s_totalCollateralShares;

    mapping(address protocol => mapping(address account => mapping(address token => uint256 amount))) public
        s_collateral;
    mapping(address protocol => mapping(address tokend => uint256 totalCollateral)) public s_totalCollateral;

    mapping(address protocol => mapping(address account => mapping(address token => uint256 amount))) public s_debt;
    mapping(address protocol => mapping(address tokend => uint256 totalDebt)) public s_totalDebt;

    mapping(address protocol => mapping(address account => mapping(address token => uint256 amount))) public
        s_accountYield;
    mapping(address protocol => mapping(address tokend => uint256 totalAccountYield)) public s_totalAccountYield;

    mapping(address protocol => mapping(address tokend => uint256)) public s_totalRevenueShares;

    event Advance_Taken(
        address indexed protocol,
        address indexed account,
        address indexed token,
        uint256 collateral,
        uint256 advancePlusFee
    );
    event Withdraw_Collateral(
        address indexed protocol, address indexed account, address indexed token, uint256 collateralWithdrawn
    );
    event Advance_Repayment_Deposit(
        address indexed protocol,
        address indexed account,
        address indexed token,
        uint256 repaidAmount,
        uint256 currentDebt
    );

    event Revenue_Claimed(address indexed protocol, uint256 revAmount);

    constructor(address _addressProvider) {
        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_pool = IPool(i_addressesProvider.getPool());
    }

    function getAdvance(address _account, address _token, uint256 _collateral, uint256 _advanceAmount) external {
        address protocol = msg.sender;

        uint256 advanceFee = _getAdvanceFee(_collateral, _advanceAmount);
        uint256 advancePlusFee = _advanceAmount + advanceFee;
        uint256 advanceMinusFee = _advanceAmount - advanceFee;
        uint256 collateralSharesMinted = _mintShares(_token, _collateral);

        s_collateralShares[protocol][_account][_token] += collateralSharesMinted;
        s_collateral[protocol][_account][_token] += _collateral;
        s_debt[protocol][_account][_token] += advanceMinusFee;

        s_totalCollateralShares[protocol][_token] += collateralSharesMinted;
        s_totalCollateral[protocol][_token] += _collateral;
        s_totalDebt[protocol][_token] += advanceMinusFee;
        s_totalRevenueShares[protocol][_token] += advanceFee;

        // SAYV NEEDS
        // add FEE to rev shares
        // make transfers
        // update balances. collateral minus advance and fee should be subtracted from shares
        // so they cant withdraw it.
        // or just on any withdrawl check yield wield contract debt.
        // all debt must be paid on yieldwield to withdraw collateral

        emit Advance_Taken(protocol, _account, _token, _collateral, advancePlusFee);
    }

    function withdrawCollateral(address _account, address _token) external {
        address protocol = msg.sender;

        uint256 currentDebt = _getCurrentDebt(protocol, _account, _token);
        if (currentDebt > 0) revert REPAY_ADVANCE_TO_WITHDRAW();

        uint256 accountCollateral = s_collateral[protocol][_account][_token];
        uint256 accountShares = s_collateralShares[protocol][_account][_token];
        uint256 collateralSharesRedeemed = _redeemShares(_token, accountCollateral);
        uint256 revenueShares = accountShares - collateralSharesRedeemed;

        s_totalRevenueShares[protocol][_token] += revenueShares;
        s_totalCollateralShares[protocol][_token] -= accountShares;
        s_collateralShares[protocol][_account][_token] = 0;
        s_collateral[protocol][_account][_token] = 0;

        // SAYV NEEDS
        // make transfers
        // update balances. collateral should be re-added to shares
        // all debt must be paid on yieldwield to withdraw collateral

        emit Withdraw_Collateral(protocol, _account, _token, accountCollateral);
    }

    // MAKE AUTO WITHDRAW COLLATERAL WHEN DEBT HITS 0

    function repayAdvanceWithDeposit(address _account, address _token, uint256 _amount) external returns (uint256) {
        address protocol = msg.sender;

        uint256 currentDebt = _getCurrentDebt(protocol, _account, _token);
        if (currentDebt > 0 && _amount <= currentDebt) {
            s_debt[protocol][_account][_token] -= _amount;
            s_totalDebt[protocol][_token] -= _amount;
        }

        emit Advance_Repayment_Deposit(protocol, _account, _token, _amount, s_debt[protocol][_account][_token]);
        return s_debt[protocol][_account][_token];
    }

    function claimRevenue(address _token) external returns (uint256) {
        address protocol = msg.sender;
        uint256 numOfRevenueShares = s_totalRevenueShares[protocol][_token];
        if (numOfRevenueShares == 0) {
            revert NO_REVENUE_TO_CLAIM();
        }
        uint256 revSharesValue = getShareValue(_token, numOfRevenueShares);
        uint256 yieldTokensNeededToTransfer = _redeemShares(_token, revSharesValue);

        s_totalRevenueShares[protocol][_token] = 0;

        emit Revenue_Claimed(protocol, yieldTokensNeededToTransfer);
        return yieldTokensNeededToTransfer;
    }

    function _getCurrentDebt(address _protocol, address _account, address _token) internal returns (uint256) {
        uint256 newYieldProducedByCollateral = _trackAccountYeild(_protocol, _account, _token);

        if (newYieldProducedByCollateral > 0 && s_debt[_protocol][_account][_token] > 0) {
            s_debt[_protocol][_account][_token] -= newYieldProducedByCollateral;
            s_totalDebt[_protocol][_token] -= newYieldProducedByCollateral;
        }

        return s_debt[_protocol][_account][_token];
    }

    function _trackAccountYeild(address _protocol, address _account, address _token) internal returns (uint256) {
        uint256 valueOfShares = getShareValue(_token, s_collateralShares[_protocol][_account][_token]);
        uint256 valueOfCollateral = s_collateral[_protocol][_account][_token];
        uint256 totalYield;
        uint256 newYield;

        if (valueOfShares > valueOfCollateral) {
            totalYield = valueOfShares - valueOfCollateral;
        }

        if (totalYield > s_accountYield[_protocol][_account][_token]) {
            newYield = totalYield - s_accountYield[_protocol][_account][_token];
            s_accountYield[_protocol][_account][_token] += newYield;
            s_totalAccountYield[_protocol][_token] += newYield;
        }

        return newYield;
    }

    function _getAdvanceFee(uint256 _collateral, uint256 _advanceAmount) internal pure returns (uint256) {
        uint256 baseFeePercentage = 10;
        uint256 scaledFeePercentage = _getPercentage(_advanceAmount, _collateral);
        uint256 totalFeePercentage = baseFeePercentage + scaledFeePercentage;
        return _getPercentageAmount(_advanceAmount, totalFeePercentage);
    }

    function _getCurrentLiquidityIndex(address _token) internal view returns (uint256) {
        DataTypes.ReserveData memory reserve = i_pool.getReserveData(_token);
        return uint256(reserve.liquidityIndex) / 1e21;
    }

    function _mintShares(address _token, uint256 _amount) private view returns (uint256) {
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(_token);
        if (currentLiquidityIndex < 1) revert INVALID_LIQUIDITY_INDEX();
        return (_amount * 1e27) / currentLiquidityIndex;
    }

    function _redeemShares(address _token, uint256 _amount) private view returns (uint256) {
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(_token);
        if (currentLiquidityIndex < 1) revert INVALID_LIQUIDITY_INDEX();
        return (_amount * 1e27) / currentLiquidityIndex;
    }

    function getShareValue(address _token, uint256 _shares) public view returns (uint256) {
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(_token);
        if (currentLiquidityIndex < 1) revert INVALID_LIQUIDITY_INDEX();
        return (_shares * currentLiquidityIndex + 1e27 - 1) / 1e27;
    }

    function _getPercentage(uint256 _partNumber, uint256 _wholeNumber) internal pure returns (uint256) {
        return (_partNumber * 100) / _wholeNumber;
    }

    function _getPercentageAmount(uint256 _wholeNumber, uint256 _percent) internal pure returns (uint256) {
        return (_wholeNumber * _percent) / 100;
    }

    function getAndupdateAccountDebtFromYield(address _account, address _token) external returns (uint256) {
        address protocol = msg.sender;

        uint256 newYieldProducedByCollateral = _trackAccountYeild(protocol, _account, _token);

        if (newYieldProducedByCollateral > 0 && s_debt[protocol][_account][_token] > 0) {
            s_debt[protocol][_account][_token] -= newYieldProducedByCollateral;
            s_totalDebt[protocol][_token] -= newYieldProducedByCollateral;
        }

        return s_debt[protocol][_account][_token];
    }

    function getCollateralShares(address _account, address _token) public view returns (uint256) {
        return s_collateralShares[msg.sender][_account][_token];
    }

    function getAccountTotalYield(address _account, address _token) public view returns (uint256) {
        return s_accountYield[msg.sender][_account][_token];
    }

    function getCollateralAmount(address _account, address _token) external view returns (uint256) {
        return s_collateral[msg.sender][_account][_token];
    }

    function getTotalRevenueShares(address _token) external view returns (uint256) {
        return s_totalRevenueShares[msg.sender][_token];
    }

    function getTotalRevenueShareValue(address _token) external view returns (uint256) {
        return getShareValue(_token, s_totalRevenueShares[msg.sender][_token]);
    }

    function getYieldWieldContractAddress() external view returns (address) {
        return address(this);
    }
}
