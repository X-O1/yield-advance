// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IYieldWield {
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

    function getAdvance(address _account, address _token, uint256 _collateral, uint256 _advanceAmount) external;

    function withdrawCollateral(address _account, address _token) external;

    function repayAdvanceWithDeposit(address _account, address _token, uint256 _amount) external returns (uint256);

    function claimRevenue(address _token) external returns (uint256);

    function getAndupdateAccountDebtFromYield(address _account, address _token) external returns (uint256);

    function getCollateralShares(address _account, address _token) external view returns (uint256);

    function getAccountTotalYield(address _account, address _token) external view returns (uint256);

    function getCollateralAmount(address _account, address _token) external view returns (uint256);

    function getTotalRevenueShares() external view returns (uint256);

    function getTotalRevenueShareValue(address _token) external view returns (uint256);

    function getYieldWieldContractAddress() external view returns (address);
}
