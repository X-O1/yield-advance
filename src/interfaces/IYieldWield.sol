// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IYieldWield
/// @notice Interface for the YieldWield contract that manages yield advances, collateral shares, and debt logic.
/// @dev All transfers and accounting are handled by the calling protocol. This contract only tracks metadata and yield logic.
interface IYieldWield {
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
        address indexed protocol, address indexed account, address indexed token, uint256 collateralWithdrawn
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
        returns (uint256 _advanceMinusFee);

    /**
     * @notice Allows withdrawal of all collateral for a user if they have zero debt
     * @param _account The account requesting withdrawal
     * @param _token Token to withdraw
     * @return Amount of collateral returned
     */
    function withdrawCollateral(address _account, address _token) external returns (uint256);

    /**
     * @notice Reduces user debt via direct deposit from protocol
     * @param _account The account repaying debt
     * @param _token Token used to repay
     * @param _amount Amount deposited to reduce debt
     * @return Remaining debt after repayment
     */
    function repayAdvanceWithDeposit(address _account, address _token, uint256 _amount) external returns (uint256);

    /**
     * @notice Allows protocol to claim accumulated revenue from advance fees
     * @param _token Token revenue to be claimed in
     * @return Token amount redeemed from revenue shares
     */
    function claimRevenue(address _token) external returns (uint256);

    /**
     * @notice Gets the token value for a given number of shares.
     * @param _token Token to evaluate
     * @param _shares Number of shares to convert
     * @return Token value corresponding to the share count
     */
    function getShareValue(address _token, uint256 _shares) external view returns (uint256);

    /**
     * @notice Gets user's collateral shares for a token.
     * @param _account Account to query
     * @param _token Token used as collateral
     * @return Number of shares held by the account
     */
    function getCollateralShares(address _account, address _token) external view returns (uint256);

    /**
     * @notice Returns total yield accrued for a user's collateral.
     * @param _account Account to query
     * @param _token Token to evaluate
     * @return Amount of yield accumulated
     */
    function getAccountTotalYield(address _account, address _token) external returns (uint256);

    /**
     * @notice Returns account's total debt after applying any available yield
     * @param _account Account to query
     * @param _token Token in which the debt is denominated
     * @return Updated total debt
     */
    function getDebt(address _account, address _token) external returns (uint256);

    /**
     * @notice Returns token value of all user's shares for a given token
     * @param _account Account to evaluate
     * @param _token Token being evaluated
     * @return Value of all shares held by the account
     */
    function getAccountTotalShareValue(address _account, address _token) external view returns (uint256);

    /**
     * @notice Gets raw collateral (token amount) for a user.
     * @param _account Account to query
     * @param _token Token used as collateral
     * @return Amount of collateral
     */
    function getCollateralAmount(address _account, address _token) external view returns (uint256);

    /**
     * @notice Gets total outstanding debt for a token across all users.
     * @param _token Token to evaluate
     * @return Aggregate debt amount
     */
    function getTotalDebt(address _token) external view returns (uint256);

    /**
     * @notice Gets total revenue shares accrued to the protocol.
     * @param _token Token to evaluate
     * @return Number of revenue shares held by the protocol
     */
    function getTotalRevenueShares(address _token) external view returns (uint256);

    /**
     * @notice Gets token value of all protocol revenue shares.
     * @param _token Token used for revenue shares
     * @return Token amount value of protocol's revenue shares
     */
    function getTotalRevenueShareValue(address _token) external view returns (uint256);

    /**
     * @notice Returns the address of this contract.
     * @return Contract address
     */
    function getYieldWieldContractAddress() external view returns (address);
}
