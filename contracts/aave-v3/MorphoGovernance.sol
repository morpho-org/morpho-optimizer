// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.0;

import "@rari-capital/solmate/src/utils/SafeTransferLib.sol";
import "./libraries/Math.sol";

import "./MorphoUtils.sol";

/// @title MorphoGovernance.
/// @author Morpho Labs.
/// @custom:contact security@morpho.xyz
/// @notice Governance functions for Morpho.
abstract contract MorphoGovernance is MorphoUtils {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using PercentageMath for uint256;
    using SafeTransferLib for ERC20;
    using WadRayMath for uint256;

    /// EVENTS ///

    /// @notice Emitted when a new `defaultMaxGasForMatching` is set.
    /// @param _defaultMaxGasForMatching The new `defaultMaxGasForMatching`.
    event DefaultMaxGasForMatchingSet(Types.MaxGasForMatching _defaultMaxGasForMatching);

    /// @notice Emitted when a new value for `maxSortedUsers` is set.
    /// @param _newValue The new value of `maxSortedUsers`.
    event MaxSortedUsersSet(uint256 _newValue);

    /// @notice Emitted when the address of the `treasuryVault` is set.
    /// @param _newTreasuryVaultAddress The new address of the `treasuryVault`.
    event TreasuryVaultSet(address indexed _newTreasuryVaultAddress);

    /// @notice Emitted when the address of the `incentivesVault` is set.
    /// @param _newIncentivesVaultAddress The new address of the `incentivesVault`.
    event IncentivesVaultSet(address indexed _newIncentivesVaultAddress);

    /// @notice Emitted when the `entryPositionsManager` is set.
    /// @param _entryPositionsManager The new address of the `entryPositionsManager`.
    event EntryPositionsManagerSet(address indexed _entryPositionsManager);

    /// @notice Emitted when the `exitPositionsManager` is set.
    /// @param _exitPositionsManager The new address of the `exitPositionsManager`.
    event ExitPositionsManagerSet(address indexed _exitPositionsManager);

    /// @notice Emitted when the `rewardsManager` is set.
    /// @param _newRewardsManagerAddress The new address of the `rewardsManager`.
    event RewardsManagerSet(address indexed _newRewardsManagerAddress);

    /// @notice Emitted when the `interestRatesManager` is set.
    /// @param _interestRatesManager The new address of the `interestRatesManager`.
    event InterestRatesSet(address indexed _interestRatesManager);

    /// @notice Emitted when the address of the `rewardsController` is set.
    /// @param _rewardsController The new address of the `rewardsController`.
    event RewardsControllerSet(address indexed _rewardsController);

    /// @notice Emitted when the `reserveFactor` is set.
    /// @param _poolTokenAddress The address of the concerned market.
    /// @param _newValue The new value of the `reserveFactor`.
    event ReserveFactorSet(address indexed _poolTokenAddress, uint16 _newValue);

    /// @notice Emitted when the `p2pIndexCursor` is set.
    /// @param _poolTokenAddress The address of the concerned market.
    /// @param _newValue The new value of the `p2pIndexCursor`.
    event P2PIndexCursorSet(address indexed _poolTokenAddress, uint16 _newValue);

    /// @notice Emitted when a reserve fee is claimed.
    /// @param _poolTokenAddress The address of the concerned market.
    /// @param _amountClaimed The amount of reward token claimed.
    event ReserveFeeClaimed(address indexed _poolTokenAddress, uint256 _amountClaimed);

    /// @notice Emitted when the value of `p2pDisabled` is set.
    /// @param _poolTokenAddress The address of the concerned market.
    /// @param _p2pDisabled The new value of `_p2pDisabled` adopted.
    event P2PStatusSet(address indexed _poolTokenAddress, bool _p2pDisabled);

    /// @notice Emitted when a market is paused or unpaused.
    /// @param _poolTokenAddress The address of the concerned market.
    /// @param _newStatus The new pause status of the market.
    event PauseStatusSet(address indexed _poolTokenAddress, bool _newStatus);

    /// @notice Emitted when a market is partially paused or unpaused.
    /// @param _poolTokenAddress The address of the concerned market.
    /// @param _newStatus The new partial pause status of the market.
    event PartialPauseStatusSet(address indexed _poolTokenAddress, bool _newStatus);

    /// @notice Emitted when claiming rewards is paused or unpaused.
    /// @param _newStatus The new claiming rewards status.
    event ClaimRewardsPauseStatusSet(bool _newStatus);

    /// @notice Emitted when a new market is created.
    /// @param _poolTokenAddress The address of the market that has been created.
    /// @param _reserveFactor The reserve factor set for this market.
    /// @param _poolTokenAddress The P2P index cursor set for this market.
    event MarketCreated(
        address indexed _poolTokenAddress,
        uint16 _reserveFactor,
        uint16 _p2pIndexCursor
    );

    /// ERRORS ///

    /// @notice Thrown when the market is not listed on Aave.
    error MarketIsNotListedOnAave();

    /// @notice Thrown when the input is above the max basis points value (100%).
    error ExceedsMaxBasisPoints();

    /// @notice Thrown when the market is already created.
    error MarketAlreadyCreated();

    /// @notice Thrown when trying to set the max sorted users to 0.
    error MaxSortedUsersCannotBeZero();

    /// @notice Thrown when the number of markets will exceed the bitmask's capacity.
    error MaxNumberOfMarkets();

    /// @notice Thrown when the address is the zero address.
    error ZeroAddress();

    /// UPGRADE ///

    /// @notice Initializes the Morpho contract.
    /// @param _entryPositionsManager The `entryPositionsManager`.
    /// @param _exitPositionsManager The `exitPositionsManager`.
    /// @param _interestRatesManager The `interestRatesManager`.
    /// @param _lendingPoolAddressesProvider The `addressesProvider`.
    /// @param _defaultMaxGasForMatching The `defaultMaxGasForMatching`.
    /// @param _maxSortedUsers The `_maxSortedUsers`.
    function initialize(
        IEntryPositionsManager _entryPositionsManager,
        IExitPositionsManager _exitPositionsManager,
        IInterestRatesManager _interestRatesManager,
        IPoolAddressesProvider _lendingPoolAddressesProvider,
        Types.MaxGasForMatching memory _defaultMaxGasForMatching,
        uint256 _maxSortedUsers
    ) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init();

        interestRatesManager = _interestRatesManager;
        entryPositionsManager = _entryPositionsManager;
        exitPositionsManager = _exitPositionsManager;
        addressesProvider = _lendingPoolAddressesProvider;
        pool = IPool(addressesProvider.getPool());

        defaultMaxGasForMatching = _defaultMaxGasForMatching;
        maxSortedUsers = _maxSortedUsers;
    }

    /// GOVERNANCE ///

    /// @notice Sets `maxSortedUsers`.
    /// @param _newMaxSortedUsers The new `maxSortedUsers` value.
    function setMaxSortedUsers(uint256 _newMaxSortedUsers) external onlyOwner {
        if (_newMaxSortedUsers == 0) revert MaxSortedUsersCannotBeZero();
        maxSortedUsers = _newMaxSortedUsers;
        emit MaxSortedUsersSet(_newMaxSortedUsers);
    }

    /// @notice Sets `defaultMaxGasForMatching`.
    /// @param _defaultMaxGasForMatching The new `defaultMaxGasForMatching`.
    function setDefaultMaxGasForMatching(Types.MaxGasForMatching memory _defaultMaxGasForMatching)
        external
        onlyOwner
    {
        defaultMaxGasForMatching = _defaultMaxGasForMatching;
        emit DefaultMaxGasForMatchingSet(_defaultMaxGasForMatching);
    }

    /// @notice Sets the `entryPositionsManager`.
    /// @param _entryPositionsManager The new `entryPositionsManager`.
    function setEntryPositionsManager(IEntryPositionsManager _entryPositionsManager)
        external
        onlyOwner
    {
        entryPositionsManager = _entryPositionsManager;
        emit EntryPositionsManagerSet(address(_entryPositionsManager));
    }

    /// @notice Sets the `exitPositionsManager`.
    /// @param _exitPositionsManager The new `exitPositionsManager`.
    function setExitPositionsManager(IExitPositionsManager _exitPositionsManager)
        external
        onlyOwner
    {
        exitPositionsManager = _exitPositionsManager;
        emit ExitPositionsManagerSet(address(_exitPositionsManager));
    }

    /// @notice Sets the `rewardsManager`.
    /// @param _rewardsManager The new `rewardsManager`.
    function setRewardsManager(IRewardsManager _rewardsManager) external onlyOwner {
        rewardsManager = _rewardsManager;
        emit RewardsManagerSet(address(_rewardsManager));
    }

    /// @notice Sets the `interestRatesManager`.
    /// @param _interestRatesManager The new `interestRatesManager` contract.
    function setInterestRatesManager(IInterestRatesManager _interestRatesManager)
        external
        onlyOwner
    {
        interestRatesManager = _interestRatesManager;
        emit InterestRatesSet(address(_interestRatesManager));
    }

    /// @notice Sets the `treasuryVault`.
    /// @param _treasuryVault The address of the new `treasuryVault`.
    function setTreasuryVault(address _treasuryVault) external onlyOwner {
        treasuryVault = _treasuryVault;
        emit TreasuryVaultSet(_treasuryVault);
    }

    /// @notice Sets the `rewardsController`.
    /// @param _rewardsController The address of the new `rewardsController`.
    function setRewardsController(address _rewardsController) external onlyOwner {
        rewardsController = IRewardsController(_rewardsController);
        emit RewardsControllerSet(_rewardsController);
    }

    /// @notice Sets the `incentivesVault`.
    /// @param _incentivesVault The new `incentivesVault`.
    function setIncentivesVault(IIncentivesVault _incentivesVault) external onlyOwner {
        incentivesVault = _incentivesVault;
        emit IncentivesVaultSet(address(_incentivesVault));
    }

    /// @notice Sets the `reserveFactor`.
    /// @param _poolTokenAddress The market on which to set the `_newReserveFactor`.
    /// @param _newReserveFactor The proportion of the interest earned by users sent to the DAO, in basis point.
    function setReserveFactor(address _poolTokenAddress, uint16 _newReserveFactor)
        external
        onlyOwner
        isMarketCreated(_poolTokenAddress)
    {
        if (_newReserveFactor > MAX_BASIS_POINTS) revert ExceedsMaxBasisPoints();
        _updateIndexes(_poolTokenAddress);

        marketParameters[_poolTokenAddress].reserveFactor = _newReserveFactor;
        emit ReserveFactorSet(_poolTokenAddress, _newReserveFactor);
    }

    /// @notice Sets a new peer-to-peer cursor.
    /// @param _poolTokenAddress The address of the market to update.
    /// @param _p2pIndexCursor The new peer-to-peer cursor.
    function setP2PIndexCursor(address _poolTokenAddress, uint16 _p2pIndexCursor)
        external
        onlyOwner
        isMarketCreated(_poolTokenAddress)
    {
        if (_p2pIndexCursor > MAX_BASIS_POINTS) revert ExceedsMaxBasisPoints();
        _updateIndexes(_poolTokenAddress);

        marketParameters[_poolTokenAddress].p2pIndexCursor = _p2pIndexCursor;
        emit P2PIndexCursorSet(_poolTokenAddress, _p2pIndexCursor);
    }

    /// @notice Sets the pause status for all markets.
    /// @param _newStatus The new status to set.
    function setPauseStatusForAllMarkets(bool _newStatus) external onlyOwner {
        uint256 numberOfMarketsCreated = marketsCreated.length;

        for (uint256 i; i < numberOfMarketsCreated; ) {
            address poolToken = marketsCreated[i];

            marketStatus[poolToken].isPaused = _newStatus;
            emit PauseStatusSet(poolToken, _newStatus);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Sets the pause status on a specific market in case of emergency.
    /// @param _poolTokenAddress The address of the market to pause/unpause.
    /// @param _newStatus The new status to set.
    function setPauseStatus(address _poolTokenAddress, bool _newStatus)
        external
        onlyOwner
        isMarketCreated(_poolTokenAddress)
    {
        marketStatus[_poolTokenAddress].isPaused = _newStatus;
        emit PauseStatusSet(_poolTokenAddress, _newStatus);
    }

    /// @notice Sets the partial pause status on a specific market in case of emergency.
    /// @param _poolTokenAddress The address of the market to partially pause/unpause.
    /// @param _newStatus The new status to set.
    function setPartialPauseStatus(address _poolTokenAddress, bool _newStatus)
        external
        onlyOwner
        isMarketCreated(_poolTokenAddress)
    {
        marketStatus[_poolTokenAddress].isPartiallyPaused = _newStatus;
        emit PartialPauseStatusSet(_poolTokenAddress, _newStatus);
    }

    /// @notice Sets the peer-to-peer disable status.
    /// @param _poolTokenAddress The address of the market of which to enable/disable peer-to-peer matching.
    /// @param _newStatus The new status to set.
    function setP2PDisabled(address _poolTokenAddress, bool _newStatus)
        external
        onlyOwner
        isMarketCreated(_poolTokenAddress)
    {
        p2pDisabled[_poolTokenAddress] = _newStatus;
        emit P2PStatusSet(_poolTokenAddress, _newStatus);
    }

    /// @notice Sets the pause status on claiming rewards.
    /// @param _newStatus The new status to set.
    function setClaimRewardsPauseStatus(bool _newStatus) external onlyOwner {
        isClaimRewardsPaused = _newStatus;
        emit ClaimRewardsPauseStatusSet(_newStatus);
    }

    /// @notice Sets a market's asset as collateral.
    /// @param _poolTokenAddress The address of the market to (un)set as collateral.
    /// @param _newStatus The new status to set.
    function setAssetAsCollateral(address _poolTokenAddress, bool _newStatus)
        external
        onlyOwner
        isMarketCreated(_poolTokenAddress)
    {
        pool.setUserUseReserveAsCollateral(
            IAToken(_poolTokenAddress).UNDERLYING_ASSET_ADDRESS(),
            _newStatus
        );
    }

    /// @notice Transfers the protocol reserve fee to the DAO.
    /// @param _poolTokenAddresses The addresses of the pool token addresses on which to claim the reserve fee.
    /// @param _amounts The list of amounts of underlying tokens to claim on each market.
    function claimToTreasury(address[] calldata _poolTokenAddresses, uint256[] calldata _amounts)
        external
        onlyOwner
    {
        if (treasuryVault == address(0)) revert ZeroAddress();

        uint256 numberOfMarkets = _poolTokenAddresses.length;

        for (uint256 i; i < numberOfMarkets; ++i) {
            address poolToken = _poolTokenAddresses[i];

            Types.MarketStatus memory status = marketStatus[poolToken];
            if (!status.isCreated || status.isPaused || status.isPartiallyPaused) continue;

            ERC20 underlyingToken = ERC20(IAToken(poolToken).UNDERLYING_ASSET_ADDRESS());
            uint256 underlyingBalance = underlyingToken.balanceOf(address(this));

            if (underlyingBalance == 0) continue;

            uint256 toClaim = Math.min(_amounts[i], underlyingBalance);

            underlyingToken.safeTransfer(treasuryVault, toClaim);
            emit ReserveFeeClaimed(poolToken, toClaim);
        }
    }

    /// @notice Creates a new market to borrow/supply in.
    /// @param _underlyingTokenAddress The underlying address of the given market.
    /// @param _marketParams The market's parameters to set.
    function createMarket(
        address _underlyingTokenAddress,
        Types.MarketParameters calldata _marketParams
    ) external onlyOwner {
        if (
            _marketParams.p2pIndexCursor > MAX_BASIS_POINTS ||
            _marketParams.reserveFactor > MAX_BASIS_POINTS
        ) revert ExceedsMaxBasisPoints();

        if (!pool.getConfiguration(_underlyingTokenAddress).getActive())
            revert MarketIsNotListedOnAave();

        address poolTokenAddress = pool.getReserveData(_underlyingTokenAddress).aTokenAddress;

        if (marketStatus[poolTokenAddress].isCreated) revert MarketAlreadyCreated();
        marketStatus[poolTokenAddress].isCreated = true;

        p2pSupplyIndex[poolTokenAddress] = WadRayMath.RAY;
        p2pBorrowIndex[poolTokenAddress] = WadRayMath.RAY;

        Types.PoolIndexes storage poolIndexes = poolIndexes[poolTokenAddress];

        poolIndexes.lastUpdateTimestamp = uint32(block.timestamp);
        poolIndexes.poolSupplyIndex = uint112(
            pool.getReserveNormalizedIncome(_underlyingTokenAddress)
        );
        poolIndexes.poolBorrowIndex = uint112(
            pool.getReserveNormalizedVariableDebt(_underlyingTokenAddress)
        );
        marketParameters[poolTokenAddress] = _marketParams;

        if (marketsCreated.length >= MAX_NB_OF_MARKETS) revert MaxNumberOfMarkets();
        borrowMask[poolTokenAddress] = 1 << (marketsCreated.length << 1);
        marketsCreated.push(poolTokenAddress);

        emit MarketCreated(
            poolTokenAddress,
            _marketParams.reserveFactor,
            _marketParams.p2pIndexCursor
        );
    }
}
