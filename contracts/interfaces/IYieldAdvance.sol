// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IYieldAdvance
 * @notice Interface for YieldAdvance contract handling collateralized yield advances and revenue tracking
 * @dev All amounts returned are denominated in RAY units (1e27)
 */
interface IYieldAdvance {
    /**
     * @notice Emitted when an advance is issued to a user
     * @param protocol The address of the calling protocol initiating the advance
     * @param account The user receiving the advance
     * @param token The token used for the collateral and advance
     * @param collateral The amount of collateral posted by the user (in base units)
     * @param advancePlusFee The total value of the advance including protocol fee (in RAY)
     */
    event Advance_Taken(
        address indexed protocol,
        address indexed account,
        address indexed token,
        uint256 collateral,
        uint256 advancePlusFee
    );

    /**
     * @notice Emitted when a user successfully withdraws their collateral
     * @param protocol The address of the protocol calling the withdrawal
     * @param account The user withdrawing collateral
     * @param token The token used as collateral
     * @param collateralWithdrawn The amount of collateral returned to the user (in RAY)
     */
    event Withdraw_Collateral(
        address indexed protocol, address indexed account, address indexed token, uint256 collateralWithdrawn
    );

    /**
     * @notice Emitted when a user repays their advance using a direct deposit
     * @param protocol The address of the protocol processing the repayment
     * @param account The user repaying the debt
     * @param token The token used for repayment
     * @param repaidAmount The amount deposited to repay the debt (in RAY)
     * @param currentDebt The remaining debt after repayment (in RAY)
     */
    event Advance_Repayment_Deposit(
        address indexed protocol,
        address indexed account,
        address indexed token,
        uint256 repaidAmount,
        uint256 currentDebt
    );

    /**
     * @notice Emitted when a protocol claims its accumulated revenue.
     * @param protocol The address of the protocol claiming the revenue.
     * @param revAmount The amount of revenue claimed, denominated (in RAY)
     */
    event Revenue_Claimed(address indexed protocol, uint256 revAmount);

    /**
     * @notice Issues an advance to a user against their collateral.
     * @param _account The user receiving the advance
     * @param _token Token used as collateral
     * @param _collateral Collateral amount (base units)
     * @param _advanceAmount Amount to advance (base units)
     * @return _advanceMinusFee Final amount after fees (in RAY)
     */
    function getAdvance(address _account, address _token, uint256 _collateral, uint256 _advanceAmount)
        external
        returns (uint256 _advanceMinusFee);

    /**
     * @notice Withdraws collateral after debt has been fully repaid.
     * @param _account The user withdrawing collateral
     * @param _token Token used for collateral
     * @return Amount of collateral returned (in RAY)
     */
    function withdrawCollateral(address _account, address _token) external returns (uint256);

    /**
     * @notice Repays debt using a direct token deposit.
     * @param _account User account
     * @param _token Token to repay with
     * @param _amount Amount being deposited (base units)
     * @return Remaining debt after repayment (in RAY)
     */
    function repayAdvanceWithDeposit(address _account, address _token, uint256 _amount) external returns (uint256);

    /**
     * @notice Claims accumulated revenue shares for the calling protocol.
     * @param _token Token to claim revenue in
     * @return Claimed value (in RAY)
     */
    function claimRevenue(address _token) external returns (uint256);

    /**
     * @notice Returns current value of shares based on Aave liquidity index.
     * @param _token Token address
     * @param _shares Amount of shares in RAY
     * @return Value in base units (in RAY)
     */
    function getShareValue(address _token, uint256 _shares) external view returns (uint256);

    /**
     * @notice Gets collateral shares held by an account.
     * @param _account User account address
     * @param _token Token address
     * @return Number of shares (in RAY)
     */
    function getCollateralShares(address _account, address _token) external view returns (uint256);

    /**
     * @notice Returns total yield earned by an account so far.
     * @param _account User account address
     * @param _token Token address
     * @return Amount of yield in RAY
     */
    function getAccountTotalYield(address _account, address _token) external returns (uint256);

    /**
     * @notice Returns debt owed by an account, updated with any applicable yield.
     * @param _account User account address
     * @param _token Token address
     * @return Updated debt value (in RAY)
     */
    function getDebt(address _account, address _token) external returns (uint256);

    /**
     * @notice Gets total value of all shares held by an account.
     * @param _account User address
     * @param _token Token address
     * @return Value in base units (in RAY)
     */
    function getAccountTotalShareValue(address _account, address _token) external view returns (uint256);

    /**
     * @notice Gets raw collateral (in RAY) held by account.
     * @param _account User address
     * @param _token Token address
     * @return Amount (in RAY)
     */
    function getCollateralAmount(address _account, address _token) external view returns (uint256);

    /**
     * @notice Returns total debt issued by protocol for a token.
     * @param _token Token address
     * @return Total debt (in RAY)
     */
    function getTotalDebt(address _token) external view returns (uint256);

    /**
     * @notice Returns total revenue shares held by protocol for token.
     * @param _token Token address
     * @return Revenue shares (in RAY)
     */
    function getTotalRevenueShares(address _token) external view returns (uint256);

    /**
     * @notice Returns current value of all revenue shares held by protocol.
     * @param _token Token address
     * @return Value in base units (in RAY)
     */
    function getTotalRevenueShareValue(address _token) external view returns (uint256);

    /**
     * @notice Returns this contract’s address.
     * @return Contract address
     */
    function getYieldAdvanceContractAddress() external view returns (address);
}
