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

contract YieldWield {
    /// @notice Aave pool instance used to retrieve liquidity index
    IPool private immutable i_pool;

    /// @notice Aave addresses provider
    IPoolAddressesProvider public immutable i_addressesProvider;

    // ========== MAPPINGS ==========

    /// @notice User shares that represent the percentage ownership of all current collateral per token across a protocol
    mapping(address protocol => mapping(address account => mapping(address token => uint256 shares)))
        public s_collateralShares;

    /// @notice Total shares per token across a protocol
    mapping(address protocol => mapping(address token => uint256 totalShares)) public s_totalCollateralShares;

    /// @notice Raw advance collateral amount for a user in a protocol
    mapping(address protocol => mapping(address account => mapping(address token => uint256 amount)))
        public s_collateral;

    /// @notice Total collateral across a protocol for a given token
    mapping(address protocol => mapping(address token => uint256 totalCollateral)) public s_totalCollateral;

    /// @notice Debt owed by an account that has taken an advance on its yield within a protocol
    mapping(address protocol => mapping(address account => mapping(address token => uint256 amount)))
        public s_debt;

    /// @notice Total protocol debt for all yield advances for a token
    mapping(address protocol => mapping(address token => uint256 totalDebt)) public s_totalDebt;

    /// @notice Tracked yield earned for a user's collateral
    mapping(address protocol => mapping(address account => mapping(address token => uint256 amount)))
        public s_accountYield;

    /// @notice Total tracked yield earned by all users collateral for a token
    mapping(address protocol => mapping(address token => uint256 totalAccountYield))
        public s_totalAccountYield;

    /// @notice Total shares that are considered revenue (advance fees collected) for the protocol
    mapping(address protocol => mapping(address token => uint256)) public s_totalRevenueShares;

    // ========== EVENTS ==========

    /// @notice Emitted when a user takes an advance against future yield
    event Advance_Taken(
        address indexed protocol,
        address indexed account,
        address indexed token,
        uint256 collateral,
        uint256 advancePlusFee
    );

    /// @notice Emitted when collateral is withdrawn (after debt repayment)
    event Withdraw_Collateral(
        address indexed protocol,
        address indexed account,
        address indexed token,
        uint256 collateralWithdrawn
    );

    /// @notice Emitted when a user repays advance debt by depositing
    event Advance_Repayment_Deposit(
        address indexed protocol,
        address indexed account,
        address indexed token,
        uint256 repaidAmount,
        uint256 currentDebt
    );

    /// @notice Emitted when protocol claims its revenue (fees)
    event Revenue_Claimed(address indexed protocol, uint256 revAmount);

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Sets the address provider and retrieves the Aave pool
     * @param _addressProvider Aave PoolAddressesProvider address
     */
    constructor(address _addressProvider) {
        i_addressesProvider = IPoolAddressesProvider(_addressProvider);
        i_pool = IPool(i_addressesProvider.getPool());
    }

    // ========== CORE FUNCTIONS ==========

    /**
     * @notice Called by protocol to grant advance to user and register debt/collateral
     * @param _account Target user account
     * @param _token Token used as collateral and for advance
     * @param _collateral Amount of tokens to register as collateral
     * @param _advanceAmount Requested advance (pre-fee)
     * @return _advanceMinusFee Actual amount user receives after fees
     */
    function getAdvance(
        address _account,
        address _token,
        uint256 _collateral,
        uint256 _advanceAmount
    ) external returns (uint256 _advanceMinusFee) {
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

        uint256 currentDebt = _getAccountCurrentDebt(protocol, _account, _token);
        if (currentDebt > 0) revert REPAY_ADVANCE_TO_WITHDRAW();

        uint256 accountCollateral = s_collateral[protocol][_account][_token];
        uint256 accountShares = s_collateralShares[protocol][_account][_token];
        uint256 collateralSharesRedeemed = _redeemShares(_token, accountCollateral);
        uint256 revenueShares = accountShares - collateralSharesRedeemed;

        s_totalRevenueShares[protocol][_token] += revenueShares;
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
    function repayAdvanceWithDeposit(
        address _account,
        address _token,
        uint256 _amount
    ) external returns (uint256) {
        address protocol = msg.sender;

        uint256 currentDebt = _getAccountCurrentDebt(protocol, _account, _token);
        if (currentDebt > 0 && _amount <= currentDebt) {
            s_debt[protocol][_account][_token] -= _amount;
            s_totalDebt[protocol][_token] -= _amount;
        }

        emit Advance_Repayment_Deposit(
            protocol,
            _account,
            _token,
            _amount,
            s_debt[protocol][_account][_token]
        );
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
        if (numOfRevenueShares == 0) {
            revert NO_REVENUE_TO_CLAIM();
        }
        uint256 revSharesValue = getShareValue(_token, numOfRevenueShares);
        uint256 yieldTokensNeededToTransfer = _redeemShares(_token, revSharesValue);

        s_totalRevenueShares[protocol][_token] = 0;

        emit Revenue_Claimed(protocol, yieldTokensNeededToTransfer);
        return yieldTokensNeededToTransfer;
    }

    /**
     * @notice Updates yield and applies any to outstanding debt
     * @param _account Account whose debt should be updated
     * @param _token Token to evaluate
     * @return Updated debt after applying yield offset
     */
    function getAndupdateAccountDebtFromYield(address _account, address _token) external returns (uint256) {
        address protocol = msg.sender;

        uint256 newYieldProducedByCollateral = _trackAccountYeild(protocol, _account, _token);

        if (newYieldProducedByCollateral > 0 && s_debt[protocol][_account][_token] > 0) {
            s_debt[protocol][_account][_token] -= newYieldProducedByCollateral;
            s_totalDebt[protocol][_token] -= newYieldProducedByCollateral;
        }

        return s_debt[protocol][_account][_token];
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @dev Internal helper that checks for new yield, updates state, and applies yield to reduce debt.
     */
    function _getAccountCurrentDebt(
        address _protocol,
        address _account,
        address _token
    ) internal returns (uint256) {
        uint256 newYieldProducedByCollateral = _trackAccountYeild(_protocol, _account, _token);

        if (newYieldProducedByCollateral > 0 && s_debt[_protocol][_account][_token] > 0) {
            s_debt[_protocol][_account][_token] -= newYieldProducedByCollateral;
            s_totalDebt[_protocol][_token] -= newYieldProducedByCollateral;
        }

        return s_debt[_protocol][_account][_token];
    }

    /**
     * @dev Tracks yield from collateral shares and updates user's yield history.
     */
    function _trackAccountYeild(
        address _protocol,
        address _account,
        address _token
    ) internal returns (uint256) {
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

    /**
     * @dev Calculates advance fee based on collateral ratio and base percentage.
     */
    function _getAdvanceFee(uint256 _collateral, uint256 _advanceAmount) internal pure returns (uint256) {
        uint256 baseFeePercentage = 10;
        uint256 scaledFeePercentage = _getPercentage(_advanceAmount, _collateral);
        uint256 totalFeePercentage = baseFeePercentage + scaledFeePercentage;
        return _getPercentageAmount(_advanceAmount, totalFeePercentage);
    }

    /**
     * @dev Gets the Aave liquidity index (scaled down to 1e6).
     */
    function _getCurrentLiquidityIndex(address _token) internal view returns (uint256) {
        DataTypes.ReserveData memory reserve = i_pool.getReserveData(_token);
        return uint256(reserve.liquidityIndex) / 1e21;
    }

    /**
     * @dev Converts token amount into shares using Aave liquidity index.
     */
    function _mintShares(address _token, uint256 _amount) private view returns (uint256) {
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(_token);
        if (currentLiquidityIndex < 1) revert INVALID_LIQUIDITY_INDEX();
        return (_amount * 1e27) / currentLiquidityIndex;
    }

    /**
     * @dev Converts shares into token value using Aave liquidity index.
     */
    function _redeemShares(address _token, uint256 _amount) private view returns (uint256) {
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(_token);
        if (currentLiquidityIndex < 1) revert INVALID_LIQUIDITY_INDEX();
        return (_amount * 1e27) / currentLiquidityIndex;
    }

    /**
     * @notice Gets the token value for a given number of shares.
     */
    function getShareValue(address _token, uint256 _shares) public view returns (uint256) {
        uint256 currentLiquidityIndex = _getCurrentLiquidityIndex(_token);
        if (currentLiquidityIndex < 1) revert INVALID_LIQUIDITY_INDEX();
        return (_shares * currentLiquidityIndex + 1e27 - 1) / 1e27;
    }

    /**
     * @dev Returns percentage of a part relative to a whole (0-100).
     */
    function _getPercentage(uint256 _partNumber, uint256 _wholeNumber) internal pure returns (uint256) {
        return (_partNumber * 100) / _wholeNumber;
    }

    /**
     * @dev Returns the amount that represents a percentage of a whole.
     */
    function _getPercentageAmount(uint256 _wholeNumber, uint256 _percent) internal pure returns (uint256) {
        return (_wholeNumber * _percent) / 100;
    }

    /**
     * @notice Gets user's collateral shares for a token.
     */
    function getCollateralShares(address _account, address _token) public view returns (uint256) {
        return s_collateralShares[msg.sender][_account][_token];
    }

    /**
     * @notice Returns total yield accrued for a user's collateral.
     */
    function getAccountTotalYield(address _account, address _token) public view returns (uint256) {
        return s_accountYield[msg.sender][_account][_token];
    }

    /**
     * @notice Gets raw collateral (token amount) for a user.
     */
    function getCollateralAmount(address _account, address _token) external view returns (uint256) {
        return s_collateral[msg.sender][_account][_token];
    }

    /**
     * @notice Gets total outstanding debt for a token across all users.
     */
    function getTotalDebt(address _token) external view returns (uint256) {
        return s_totalDebt[msg.sender][_token];
    }

    /**
     * @notice Gets total revenue shares accrued to the protocol.
     */
    function getTotalRevenueShares(address _token) external view returns (uint256) {
        return s_totalRevenueShares[msg.sender][_token];
    }

    /**
     * @notice Gets token value of all protocol revenue shares.
     */
    function getTotalRevenueShareValue(address _token) external view returns (uint256) {
        return getShareValue(_token, s_totalRevenueShares[msg.sender][_token]);
    }

    /**
     * @notice Returns the address of this contract.
     */
    function getYieldWieldContractAddress() external view returns (address) {
        return address(this);
    }
}
