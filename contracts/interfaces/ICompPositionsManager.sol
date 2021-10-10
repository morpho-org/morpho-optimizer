// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.7;

interface ICompPositionsManager {
    function createMarkets(address[] memory markets) external returns (uint256[] memory);

    function setComptroller(address _proxyComptrollerAddress) external;
}
