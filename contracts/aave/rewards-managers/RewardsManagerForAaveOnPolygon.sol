// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.7;

import "../RewardsManagerForAave.sol";

contract RewardsManagerForAaveOnPolygon is RewardsManagerForAave {
    constructor(
        ILendingPool _lendingPool,
        IPositionsManagerForAave _positionsManager,
        address _swapManager
    ) RewardsManagerForAave(_lendingPool, _positionsManager, _swapManager) {}

    /// @inheritdoc RewardsManagerForAave
    function _getUpdatedIndex(address _asset, uint256 _totalStaked)
        internal
        override
        returns (uint256 newIndex)
    {
        LocalAssetData storage localData = localAssetData[_asset];
        uint256 blockTimestamp = block.timestamp;
        uint256 lastTimestamp = localData.lastUpdateTimestamp;

        if (blockTimestamp == lastTimestamp) return localData.lastIndex;
        else {
            IAaveIncentivesController.AssetData memory assetData = aaveIncentivesController.assets(
                _asset
            );
            uint256 oldIndex = assetData.index;
            uint128 lastTimestampOnAave = assetData.lastUpdateTimestamp;

            if (blockTimestamp == lastTimestampOnAave) newIndex = oldIndex;
            else
                newIndex = _getAssetIndex(
                    oldIndex,
                    assetData.emissionPerSecond,
                    lastTimestampOnAave,
                    _totalStaked
                );

            localData.lastUpdateTimestamp = blockTimestamp;
            localData.lastIndex = newIndex;
        }
    }
}
