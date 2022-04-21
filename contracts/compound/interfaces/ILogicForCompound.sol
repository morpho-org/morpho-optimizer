// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.13;

interface ILogicForCompound {
    function supply(
        address _poolTokenAddress,
        uint256 _amount,
        uint256 _maxGasToConsume
    ) external;

    function borrow(
        address _poolTokenAddress,
        uint256 _amount,
        uint256 _maxGasToConsume
    ) external;

    function withdraw(
        address _poolTokenAddress,
        uint256 _amount,
        address _supplier,
        address _receiver,
        uint256 _maxGasToConsume
    ) external;

    function repay(
        address _poolTokenAddress,
        address _user,
        uint256 _amount,
        uint256 _maxGasToConsume
    ) external;

    function checkUserLiquidity(
        address _user,
        address _poolTokenAddress,
        uint256 _withdrawnAmount,
        uint256 _borrowedAmount
    ) external;
}
