// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title YieldWield
 * @notice Handles logic for yield advances, debt accounting, and collateral tracking using share mechanics.
 * @dev All actual token transfers and accounting are handled by the calling protocol. This contract only manages metadata and logic for shares, debt, and protocol-specific revenue.
 */
import "./YieldWieldErrors.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {DataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";

contract YieldWield {
    using WadRayMath for uint256;

    // Aave pool instance used to retrieve liquidity index
    IPool private immutable i_pool;

    // Aave addresses provider
    IPoolAddressesProvider public immutable i_addressesProvider;

    // User shares that represent the percentage ownership of all current collateral per token across a protocol
    mapping(address protocol => mapping(address account => mapping(address token => uint256 shares))) public
        s_collateralShares;
    mapping(address protocol => mapping(address token => uint256 totalShares)) public s_totalCollateralShares;

    // Raw advance collateral amount for a user in a protocol
    mapping(address protocol => mapping(address account => mapping(address token => uint256 amount))) public
        s_collateral;
    mapping(address protocol => mapping(address token => uint256 totalCollateral)) public s_totalCollateral;

    // Debt owed by an account that has taken an advance on its yield within a protocol
    mapping(address protocol => mapping(address account => mapping(address token => uint256 amount))) public s_debt;
    mapping(address protocol => mapping(address token => uint256 totalDebt)) public s_totalDebt;

    // Tracked yield earned for a user's collateral
    mapping(address protocol => mapping(address account => mapping(address token => uint256 amount))) public
        s_accountYield;
    mapping(address protocol => mapping(address token => uint256 totalAccountYield)) public s_totalAccountYield;

    // Total shares that are considered revenue (advance fees collected) for the protocol
    mapping(address protocol => mapping(address token => uint256)) public s_totalRevenueShares;

    // Emitted when a user takes an advance against future yield
    event Advance_Taken(
        address indexed protocol,
        address indexed account,
        address indexed token,
        uint256 collateral,
        uint256 advancePlusFee
    );

    // Emitted when collateral is withdrawn (after debt repayment)
    event Withdraw_Collateral(
        address indexed protocol, address indexed account, address indexed token, uint256 collateralWithdrawn
    );

    // Emitted when a user repays advance debt by depositing
    event Advance_Repayment_Deposit(
        address indexed protocol,
        address indexed account,
        address indexed token,
        uint256 repaidAmount,
        uint256 currentDebt
    );

    // Emitted when protocol claims its revenue (fees)
    event Revenue_Claimed(address indexed protocol, uint256 revAmount);

    /**
     * @notice Sets the address provider and retrieves the Aave pool
     * @param _addressProvider Aave PoolAddressesProvider address
     */
    constructor(address _addressProvider) {
        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_pool = IPool(i_addressesProvider.getPool());
    }

    /**
     * @notice Called by protocol to grant advance to user and register debt/collateral
     * @param _account Target user account
     * @param _token Token used as collateral and for advance
     * @param _collateral Amount of tokens to register as collateral
     * @param _advanceAmount Requested advance (pre-fee)
     * @return _advanceMinusFee Actual amount user receives after fees
     */
    function getAdvance(address _account, address _token, uint256 _collateral, uint256 _advanceAmount)
        external
        returns (uint256 _advanceMinusFee)
    {
        address protocol = msg.sender;
        uint256 advanceFee = _getAdvanceFee(_collateral, _advanceAmount);
        uint256 advancePlusFee = _advanceAmount + advanceFee;
        uint256 advanceMinusFee = _advanceAmount - advanceFee;

        uint256 currentIndex = _getCurrentLiquidityIndex(_token);
        uint256 collateralSharesMinted = _collateral.rayDiv(currentIndex);
        uint256 revenueSharesMinted = advanceFee.rayDiv(currentIndex);

        s_collateralShares[protocol][_account][_token] += collateralSharesMinted;
        s_collateral[protocol][_account][_token] += _collateral;
        s_debt[protocol][_account][_token] += _advanceAmount;

        s_totalCollateralShares[protocol][_token] += collateralSharesMinted;
        s_totalCollateral[protocol][_token] += _collateral;
        s_totalDebt[protocol][_token] += _advanceAmount;
        s_totalRevenueShares[protocol][_token] += revenueSharesMinted;

        emit Advance_Taken(protocol, _account, _token, _collateral, advancePlusFee);
        return advanceMinusFee;
    }

    /**
     * @notice Allows withdrawal of all collateral for a user if they have zero debt
     * @param _account The account requesting withdrawal
     * @param _token Token to withdraw
     * @return Amount of collateral returned
     */
    function withdrawCollateral(address _account, address _token) external returns (uint256) {
        address protocol = msg.sender;

        uint256 currentDebt = _updateAccountDebtFromYield(_account, _token);
        if (currentDebt > 0) revert REPAY_ADVANCE_TO_WITHDRAW();

        uint256 accountCollateral = s_collateral[protocol][_account][_token];
        uint256 accountShares = s_collateralShares[protocol][_account][_token];

        s_totalCollateralShares[protocol][_token] -= accountShares;
        s_collateralShares[protocol][_account][_token] = 0;
        s_collateral[protocol][_account][_token] = 0;

        emit Withdraw_Collateral(protocol, _account, _token, accountCollateral);
        return accountCollateral;
    }

    /**
     * @notice Reduces user debt via direct deposit from protocol
     * @param _account The account repaying debt
     * @param _token Token used to repay
     * @param _amount Amount deposited to reduce debt
     * @return Remaining debt after repayment
     */
    function repayAdvanceWithDeposit(address _account, address _token, uint256 _amount) external returns (uint256) {
        address protocol = msg.sender;

        uint256 currentDebt = _updateAccountDebtFromYield(_account, _token);
        if (currentDebt > 0 && _amount <= currentDebt) {
            s_debt[protocol][_account][_token] -= _amount;
            s_totalDebt[protocol][_token] -= _amount;
        }
        emit Advance_Repayment_Deposit(protocol, _account, _token, _amount, s_debt[protocol][_account][_token]);
        return s_debt[protocol][_account][_token];
    }

    /**
     * @notice Allows protocol to claim accumulated revenue from advance fees
     * @param _token Token revenue to be claimed in
     * @return Token amount redeemed from revenue shares
     */
    function claimRevenue(address _token) external returns (uint256) {
        address protocol = msg.sender;
        uint256 numOfRevenueShares = s_totalRevenueShares[protocol][_token];
        if (numOfRevenueShares == 0) revert NO_REVENUE_TO_CLAIM();
        s_totalRevenueShares[protocol][_token] = 0;

        emit Revenue_Claimed(protocol, numOfRevenueShares);
        return numOfRevenueShares;
    }

    /**
     * @notice Updates yield and applies any to outstanding debt
     * @param _account Account whose debt should be updated
     * @param _token Token to evaluate
     */
    function _updateAccountDebtFromYield(address _account, address _token) internal returns (uint256) {
        address protocol = msg.sender;
        uint256 yieldProducedByCollateral = _trackAccountYeild(protocol, _account, _token);
        uint256 accountDebt = s_debt[protocol][_account][_token];

        if (accountDebt > 0) {
            if (yieldProducedByCollateral >= accountDebt) {
                s_debt[protocol][_account][_token] = 0;
                s_totalDebt[protocol][_token] -= accountDebt;
                s_accountYield[protocol][_account][_token] -= accountDebt;
                s_totalAccountYield[protocol][_token] -= accountDebt;
            } else if (yieldProducedByCollateral < accountDebt) {
                s_debt[protocol][_account][_token] -= yieldProducedByCollateral;
                s_totalDebt[protocol][_token] -= yieldProducedByCollateral;
                s_accountYield[protocol][_account][_token] -= yieldProducedByCollateral;
                s_totalAccountYield[protocol][_token] -= yieldProducedByCollateral;
            }
        }
        uint256 accountTotalYDebtAfterRepayment = s_debt[protocol][_account][_token];
        return accountTotalYDebtAfterRepayment;
    }

    // Tracks yield from collateral shares and updates user's yield history.
    function _trackAccountYeild(address _protocol, address _account, address _token) internal returns (uint256) {
        uint256 valueOfShares = getAccountTotalShareValue(_account, _token);
        uint256 valueOfCollateral = getCollateralAmount(_account, _token);
        uint256 totalYield;

        if (valueOfShares > valueOfCollateral) {
            totalYield = valueOfShares - valueOfCollateral;
            s_accountYield[_protocol][_account][_token] += totalYield;
            s_totalAccountYield[_protocol][_token] += totalYield;
        }
        return totalYield;
    }

    // Calculates advance fee based on collateral ratio and base percentage.
    function _getAdvanceFee(uint256 _collateral, uint256 _advanceAmount) internal pure returns (uint256) {
        uint256 baseFeePercentage = 10;
        uint256 scaledFeePercentage = (_advanceAmount * 100) / _collateral;
        uint256 totalFeePercentage = baseFeePercentage + scaledFeePercentage;
        return (_advanceAmount * totalFeePercentage) / 100;
    }

    // Gets the Aave liquidity index
    function _getCurrentLiquidityIndex(address _token) internal view returns (uint256) {
        uint256 currentIndex = uint256(i_pool.getReserveData(_token).liquidityIndex);
        if (currentIndex < 1e27) revert INVALID_LIQUIDITY_INDEX();
        return currentIndex;
    }

    // Converts token amount into shares using Aave liquidity index.
    function _convertAmountToShares(address _token, uint256 _amount) private view returns (uint256) {
        return _amount.rayDiv(_getCurrentLiquidityIndex(_token));
    }

    // Gets the token value for a given number of shares.
    function getShareValue(address _token, uint256 _shares) public view returns (uint256) {
        return _shares.rayMul(_getCurrentLiquidityIndex(_token));
    }

    // Gets user's collateral shares for a token.
    function getCollateralShares(address _account, address _token) public view returns (uint256) {
        return s_collateralShares[msg.sender][_account][_token];
    }

    // Returns total yield accrued for a user's collateral.
    function getAccountTotalYield(address _account, address _token) public returns (uint256) {
        return _trackAccountYeild(msg.sender, _account, _token);
    }

    // Returns accounts total debt
    function getDebt(address _account, address _token) external returns (uint256) {
        return _updateAccountDebtFromYield(_account, _token);
    }

    function getAccountTotalShareValue(address _account, address _token) public view returns (uint256) {
        return getCollateralShares(_account, _token).rayMul(_getCurrentLiquidityIndex(_token));
    }

    // Gets raw collateral (token amount) for a user.
    function getCollateralAmount(address _account, address _token) public view returns (uint256) {
        return s_collateral[msg.sender][_account][_token];
    }

    // Gets total outstanding debt for a token across all users.
    function getTotalDebt(address _token) external view returns (uint256) {
        return s_totalDebt[msg.sender][_token];
    }

    // Gets total revenue shares accrued to the protocol.
    function getTotalRevenueShares(address _token) external view returns (uint256) {
        return s_totalRevenueShares[msg.sender][_token];
    }

    // Gets token value of all protocol revenue shares.
    function getTotalRevenueShareValue(address _token) external view returns (uint256) {
        return getShareValue(_token, s_totalRevenueShares[msg.sender][_token]);
    }

    // Returns the address of this contract.
    function getYieldWieldContractAddress() external view returns (address) {
        return address(this);
    }
}
