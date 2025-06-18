// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./YieldWieldErrors.sol";
import {IERC20} from "@openzeppelin/ERC20/IERC20.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {DataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";

contract YieldWield {
    IPool private immutable i_pool;
    IERC20 public immutable i_vaultToken;
    address public immutable i_vaultTokenAddress;
    IERC20 public immutable i_yieldBarringToken;
    address public immutable i_yieldBarringTokenAddress;
    IPoolAddressesProvider public immutable i_addressesProvider;
    address public immutable i_yieldWieldContractAddress;

    // tracks accounts pool ownership
    mapping(address account => uint256 shares) public s_collateralShares;
    uint256 private s_totalCollateralShares;

    // amount of locked collateral in dollar value
    mapping(address account => uint256 amount) public s_collateral;
    uint256 private s_totalCollateral;

    // amount of owed from taking an advance and needs to pay back to unlock collateral
    mapping(address account => uint256 amount) public s_debt;
    uint256 private s_totalDebt;

    // amount of yield produced by an account from their collateral
    mapping(address account => uint256 amount) public s_accountYield;
    uint256 private s_totalAccountYield;
    // total profit made from advance repayments and advance fees
    uint256 private s_totalRevenueShares;

    constructor(address _token, address _addressProvider, address _yieldBarringToken) {
        i_vaultToken = IERC20(_token);
        i_vaultTokenAddress = _token;
        i_yieldBarringToken = IERC20(_yieldBarringToken);
        i_yieldBarringTokenAddress = _yieldBarringToken;
        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_pool = IPool(i_addressesProvider.getPool());
        i_yieldWieldContractAddress = address(this);
    }

    function getAdvance(address _account, uint256 _collateral, uint256 _advanceAmount) external {
        uint256 collateralSharesMinted = _mintShares(_collateral);
        uint256 advanceFee = _getAdvanceFee(_collateral, _advanceAmount);
        uint256 advancePlusFee = _advanceAmount + advanceFee;

        s_collateralShares[_account] += collateralSharesMinted;
        s_collateral[_account] += _collateral;
        s_debt[_account] += advancePlusFee;

        s_totalCollateralShares += collateralSharesMinted;
        s_totalCollateral += _collateral;
        s_totalDebt += advancePlusFee;

        i_vaultToken.transferFrom(msg.sender, _account, _advanceAmount);
        i_yieldBarringToken.transferFrom(msg.sender, address(this), _collateral);
    }

    function withdrawCollateral(address _account) external {
        uint256 currentDebt = updateAccountDebtFromYield(_account);

        if (currentDebt > 0) {
            revert REPAY_ADVANCE_TO_WITHDRAW();
        }
        uint256 accountCollateral = s_collateral[_account];
        uint256 accountShares = s_collateralShares[_account];
        uint256 collateralSharesRedeemed = _redeemShares(accountCollateral);
        uint256 revenueShares = accountShares - collateralSharesRedeemed;

        s_totalRevenueShares += revenueShares;
        s_totalCollateralShares -= accountShares;
        s_collateralShares[_account] = 0;

        i_yieldBarringToken.transfer(msg.sender, collateralSharesRedeemed);
    }

    function repayAdvanceWithDeposit(address _account, uint256 _amount) external returns (uint256) {
        uint256 currentDebt = updateAccountDebtFromYield(_account);

        if (currentDebt > 0 && _amount <= currentDebt) {
            s_debt[_account] -= _amount;
        }

        return currentDebt;
    }

    // this needs to be called by chainlink to udate periodocly
    // call before any collateral withdraw attempt
    function updateAccountDebtFromYield(address _account) public returns (uint256) {
        uint256 newYieldProducedByCollateral = _trackAccountYeild(_account);

        if (newYieldProducedByCollateral > 0 && s_debt[_account] > 0) {
            s_debt[_account] -= newYieldProducedByCollateral;
            s_totalDebt -= newYieldProducedByCollateral;
        }

        if (s_debt[_account] == 0) {
            // trasnsfer collat
        }
        return s_debt[_account];
    }

    function _getAdvanceFee(uint256 _collateral, uint256 _advanceAmount) internal pure returns (uint256) {
        uint256 baseFeePercentage = 10;
        uint256 scaledFeePercentage = _getPercentage(_advanceAmount, _collateral);
        uint256 totalFeePercentage = baseFeePercentage + scaledFeePercentage;
        uint256 totalFee = _getPercentageAmount(_advanceAmount, totalFeePercentage);
        return totalFee;
    }

    function _trackAccountYeild(address _account) internal returns (uint256) {
        uint256 valueOfShares = getShareValue(s_collateralShares[_account]);
        uint256 valueOfCollateral = getCollateralAmount(_account);

        uint256 totalYield = valueOfShares - valueOfCollateral;
        uint256 newYield;

        if (totalYield > s_accountYield[_account]) {
            newYield = totalYield - s_accountYield[_account];
            s_accountYield[_account] += newYield;
            s_totalAccountYield += newYield;
        }
        return newYield;
    }

    function _getCurrentLiquidityIndex() internal view returns (uint256) {
        DataTypes.ReserveData memory reserve = i_pool.getReserveData(i_vaultTokenAddress);
        return uint256(reserve.liquidityIndex) / 1e21; // WAD (1e27)
    }

    function _mintShares(uint256 _usdcAmount) private view returns (uint256) {
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex();
        if (currentLiquidityIndex < 1) {
            revert INVALID_LIQUIDITY_INDEX();
        }
        uint256 sharesToMint = ((_usdcAmount * 1e27) / currentLiquidityIndex);
        return sharesToMint;
    }

    function _redeemShares(uint256 _usdcAmount) private view returns (uint256) {
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex();
        if (currentLiquidityIndex < 1) {
            revert INVALID_LIQUIDITY_INDEX();
        }
        uint256 sharesToBurn = ((_usdcAmount * 1e27) / currentLiquidityIndex);
        return sharesToBurn;
    }

    function getAccountShareValue(address _account) public view returns (uint256) {
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex();
        if (currentLiquidityIndex < 1) {
            revert INVALID_LIQUIDITY_INDEX();
        }
        uint256 shareValue = (s_collateralShares[_account] * currentLiquidityIndex + 1e27 - 1) / 1e27;
        return shareValue;
    }

    function getShareValue(uint256 _shares) public view returns (uint256) {
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex();
        if (currentLiquidityIndex < 1) {
            revert INVALID_LIQUIDITY_INDEX();
        }
        uint256 shareValue = (_shares * currentLiquidityIndex + 1e27 - 1) / 1e27;
        return shareValue;
    }

    function _getPercentage(uint256 _partNumber, uint256 _wholeNumber) internal pure returns (uint256) {
        return (_partNumber * 100) / _wholeNumber;
    }

    function _getPercentageAmount(uint256 _wholeNumber, uint256 _percent) internal pure returns (uint256) {
        return (_wholeNumber * _percent) / 100;
    }

    function getCollateralShares(address _account) public view returns (uint256) {
        return s_collateralShares[_account];
    }

    function getAccountTotalYield(address _account) public view returns (uint256) {
        return s_accountYield[_account];
    }

    function getCollateralAmount(address _account) public view returns (uint256) {
        return s_collateral[_account];
    }

    function getDebtAmount(address _account) public view returns (uint256) {
        return s_debt[_account];
    }

    function getTotalRevenueShares() public view returns (uint256) {
        return s_totalRevenueShares;
    }

    function getTotalRevenueShareValue() public view returns (uint256) {
        return getShareValue(s_totalRevenueShares);
    }

    function getYieldWieldContractAddress() public view returns (address) {
        return i_yieldWieldContractAddress;
    }
}
