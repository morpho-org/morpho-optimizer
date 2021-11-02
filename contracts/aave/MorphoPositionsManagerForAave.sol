// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.7;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../libraries/RedBlackBinaryTree.sol";
import "./libraries/aave/WadRayMath.sol";
import "./interfaces/aave/ILendingPoolAddressesProvider.sol";
import "./interfaces/aave/IProtocolDataProvider.sol";
import "./interfaces/aave/ILendingPool.sol";
import "./interfaces/aave/IPriceOracleGetter.sol";
import {IVariableDebtToken} from "./interfaces/aave/IVariableDebtToken.sol";
import {IAToken} from "./interfaces/aave/IAToken.sol";
import "./interfaces/IMarketsManagerForAave.sol";

/**
 *  @title MorphoPositionsManagerForAave
 *  @dev Smart contract interacting with Aave to enable P2P supply/borrow positions that can fallback on Aave's pool using poolToken tokens.
 */
contract MorphoPositionsManagerForAave is ReentrancyGuard {
    using RedBlackBinaryTree for RedBlackBinaryTree.Tree;
    using WadRayMath for uint256;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* Structs */

    struct SupplyBalance {
        uint256 inP2P; // In p2pUnit, a unit that grows in value, to keep track of the interests/debt increase when users are in p2p.
        uint256 onPool; // In scaled balance.
    }

    struct BorrowBalance {
        uint256 inP2P; // In p2pUnit.
        uint256 onPool; // In adUnit, a unit that grows in value, to keep track of the debt increase when users are in Aave. Multiply by current borrowIndex to get the underlying amount.
    }

    // Struct to avoid stack too deep error
    struct BalanceStateVars {
        uint256 debtValue; // The total debt value (in ETH).
        uint256 maxDebtValue; // The maximum debt value available thanks to the collateral (in ETH).
        uint256 redeemedValue; // The redeemed value if any (in ETH).
        uint256 collateralValue; // The collateral value (in ETH).
        uint256 debtToAdd; // The debt to add at the current iteration.
        uint256 collateralToAdd; // The collateral to add at the current iteration.
        uint256 p2pExchangeRate; // The p2pUnit exchange rate of the `poolTokenEntered`.
        uint256 underlyingPrice; // The price of the underlying linked to the `poolTokenEntered`.
        uint256 normalizedVariableDebt; // Normalized variable debt of the market.
        uint256 normalizedIncome; // Noramlized income of the market.
        uint256 liquidationThreshold; // The liquidation threshold on Aave.
        uint256 reserveDecimals; // The number of decimals of the asset in the reserve.
        uint256 tokenUnit; // The unit of tokens considering its decimals.
        address poolTokenEntered; // The poolToken token entered by the user.
        address underlyingAddress; // The address of the underlying.
        IPriceOracleGetter oracle; // Aave oracle.
    }

    // Struct to avoid stack too deep error
    struct LiquidateVars {
        uint256 debtValue; // The debt value (in ETH).
        uint256 maxDebtValue; // The maximum debt value possible (in ETH).
        uint256 borrowBalance; // Total borrow balance of the user in underlying for a given asset.
        uint256 amountToSeize; // The amount of collateral underlying the liquidator can seize.
        uint256 borrowedPrice; // The price of the asset borrowed (in ETH).
        uint256 collateralPrice; // The price of the collateral asset (in ETH).
        uint256 normalizedIncome; // The normalized income of the asset.
        uint256 totalCollateral; // The total of collateral of the user in underlying.
        uint256 liquidationBonus; // The liquidation bonus on Aave.
        uint256 collateralReserveDecimals; // The number of decimals of the collateral asset in the reserve.
        uint256 collateralTokenUnit; // The unit of collateral token considering its decimals.
        uint256 borrowedReserveDecimals; // The number of decimals of the borrowed asset in the reserve.
        uint256 borrowedTokenUnit; // The unit of borrowed token considering its decimals.
        address tokenBorrowedAddress; // The address of the borrowed asset.
        address tokenCollateralAddress; // The address of the collateral asset.
        IPriceOracleGetter oracle; // Aave oracle.
    }

    // Struct to avoid stack too deep error
    struct MatchSuppliersVars {
        uint256 numberOfKeysAtValue;
        uint256 onAaveInUnderlying;
        uint256 highestValueSeen;
        uint256 highestValue;
    }

    /* Storage */

    uint256 public constant LIQUIDATION_CLOSE_FACTOR_PERCENT = 5000; // In basis points.
    bytes32 public constant DATA_PROVIDER_ID =
        0x1000000000000000000000000000000000000000000000000000000000000000; // Id of the data provider.

    mapping(address => RedBlackBinaryTree.Tree) private suppliersInP2P; // Suppliers in peer-to-peer.
    mapping(address => RedBlackBinaryTree.Tree) private suppliersOnPool; // Suppliers on Aave.
    mapping(address => RedBlackBinaryTree.Tree) private borrowersInP2P; // Borrowers in peer-to-peer.
    mapping(address => RedBlackBinaryTree.Tree) private borrowersOnPool; // Borrowers on Aave.
    mapping(address => mapping(address => SupplyBalance)) public supplyBalanceInOf; // For a given market, the supply balance of user.
    mapping(address => mapping(address => BorrowBalance)) public borrowBalanceInOf; // For a given market, the borrow balance of user.
    mapping(address => mapping(address => bool)) public accountMembership; // Whether the account is in the market or not.
    mapping(address => address[]) public enteredMarkets; // Markets entered by a user.
    mapping(address => uint256) public thresholds; // Thresholds below the ones suppliers and borrowers cannot enter markets.

    IMarketsManagerForAave public marketsManagerForAave;
    ILendingPoolAddressesProvider public addressesProvider;
    IProtocolDataProvider public dataProvider;
    ILendingPool public lendingPool;

    /* Events */

    /** @dev Emitted when a supply happens.
     *  @param _account The address of the supplier.
     *  @param _poolTokenAddress The address of the market where assets are supplied into.
     *  @param _amount The amount of assets.
     */
    event Supplied(address indexed _account, address indexed _poolTokenAddress, uint256 _amount);

    /** @dev Emitted when a withdraw happens.
     *  @param _account The address of the withdrawer.
     *  @param _poolTokenAddress The address of the market from where assets are withdrawn.
     *  @param _amount The amount of assets.
     */
    event Withdrawn(address indexed _account, address indexed _poolTokenAddress, uint256 _amount);

    /** @dev Emitted when a borrow happens.
     *  @param _account The address of the borrower.
     *  @param _poolTokenAddress The address of the market where assets are borrowed.
     *  @param _amount The amount of assets.
     */
    event Borrowed(address indexed _account, address indexed _poolTokenAddress, uint256 _amount);

    /** @dev Emitted when a repay happens.
     *  @param _account The address of the repayer.
     *  @param _poolTokenAddress The address of the market where assets are repaid.
     *  @param _amount The amount of assets.
     */
    event Repaid(address indexed _account, address indexed _poolTokenAddress, uint256 _amount);

    /** @dev Emitted when a supplier position is moved from Aave to P2P.
     *  @param _account The address of the supplier.
     *  @param _poolTokenAddress The address of the market.
     *  @param _amount The amount of assets.
     */
    event SupplierMatched(
        address indexed _account,
        address indexed _poolTokenAddress,
        uint256 _amount
    );

    /** @dev Emitted when a supplier position is moved from P2P to Aave.
     *  @param _account The address of the supplier.
     *  @param _poolTokenAddress The address of the market.
     *  @param _amount The amount of assets.
     */
    event SupplierUnmatched(
        address indexed _account,
        address indexed _poolTokenAddress,
        uint256 _amount
    );

    /** @dev Emitted when a borrower position is moved from Aave to P2P.
     *  @param _account The address of the borrower.
     *  @param _poolTokenAddress The address of the market.
     *  @param _amount The amount of assets.
     */
    event BorrowerMatched(
        address indexed _account,
        address indexed _poolTokenAddress,
        uint256 _amount
    );

    /** @dev Emitted when a borrower position is moved from P2P to Aave.
     *  @param _account The address of the borrower.
     *  @param _poolTokenAddress The address of the market.
     *  @param _amount The amount of assets.
     */
    event BorrowerUnmatched(
        address indexed _account,
        address indexed _poolTokenAddress,
        uint256 _amount
    );

    /* Modifiers */

    /** @dev Prevents a user to access a market not created yet.
     *  @param _poolTokenAddress The address of the market.
     */
    modifier isMarketCreated(address _poolTokenAddress) {
        require(marketsManagerForAave.isCreated(_poolTokenAddress), "mkt-not-created");
        _;
    }

    /** @dev Prevents a user to supply or borrow less than threshold.
     *  @param _poolTokenAddress The address of the market.
     *  @param _amount The amount in ERC20 tokens.
     */
    modifier isAboveThreshold(address _poolTokenAddress, uint256 _amount) {
        require(_amount >= thresholds[_poolTokenAddress], "amount<threshold");
        _;
    }

    /** @dev Prevents a user to call function only allowed for the markets manager.
     */
    modifier onlyMarketsManager() {
        require(msg.sender == address(marketsManagerForAave), "only-mkt-manager");
        _;
    }

    /* Constructor */

    constructor(address _aaveMarketsManager, address _lendingPoolAddressesProvider) {
        marketsManagerForAave = IMarketsManagerForAave(_aaveMarketsManager);
        addressesProvider = ILendingPoolAddressesProvider(_lendingPoolAddressesProvider);
        dataProvider = IProtocolDataProvider(addressesProvider.getAddress(DATA_PROVIDER_ID));
        lendingPool = ILendingPool(addressesProvider.getLendingPool());
    }

    /* External */

    /** @dev Updates the lending pool and the data provider.
     */
    function updateAaveContracts() external {
        dataProvider = IProtocolDataProvider(addressesProvider.getAddress(DATA_PROVIDER_ID));
        lendingPool = ILendingPool(addressesProvider.getLendingPool());
    }

    /** @dev Sets the threshold of a market.
     *  @param _poolTokenAddress The address of the market to set the threshold.
     *  @param _newThreshold The new threshold.
     */
    function setThreshold(address _poolTokenAddress, uint256 _newThreshold)
        external
        onlyMarketsManager
    {
        thresholds[_poolTokenAddress] = _newThreshold;
    }

    /** @dev Supplies ERC20 tokens in a specific market.
     *  @param _poolTokenAddress The address of the market the user wants to supply.
     *  @param _amount The amount to supply in ERC20 tokens.
     */
    function supply(address _poolTokenAddress, uint256 _amount)
        external
        nonReentrant
        isMarketCreated(_poolTokenAddress)
        isAboveThreshold(_poolTokenAddress, _amount)
    {
        _handleMembership(_poolTokenAddress, msg.sender);
        IAToken poolToken = IAToken(_poolTokenAddress);
        IERC20 erc20Token = IERC20(poolToken.UNDERLYING_ASSET_ADDRESS());
        erc20Token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 normalizedIncome = lendingPool.getReserveNormalizedIncome(address(erc20Token));

        /* CASE 1: Some borrowers are waiting on Aave, Morpho matches the supplier in P2P with them */
        if (borrowersOnPool[_poolTokenAddress].isNotEmpty()) {
            uint256 p2pExchangeRate = marketsManagerForAave.updateP2PUnitExchangeRate(
                _poolTokenAddress
            );
            uint256 remainingToSupplyToAave = _matchBorrowers(_poolTokenAddress, _amount); // In underlying
            uint256 matched = _amount - remainingToSupplyToAave;
            if (matched > 0) {
                supplyBalanceInOf[_poolTokenAddress][msg.sender].inP2P += matched
                    .wadToRay()
                    .rayDiv(p2pExchangeRate)
                    .rayToWad(); // In p2pUnit
            }
            /* If there aren't enough borrowers waiting on Aave to match all the tokens supplied, the rest is supplied to Aave */
            if (remainingToSupplyToAave > 0) {
                supplyBalanceInOf[_poolTokenAddress][msg.sender].onPool += remainingToSupplyToAave
                    .wadToRay()
                    .rayDiv(normalizedIncome)
                    .rayToWad(); // Scaled Balance
                _supplyERC20ToAave(_poolTokenAddress, remainingToSupplyToAave); // Revert on error
            }
        }
        /* CASE 2: There aren't any borrowers waiting on Aave, Morpho supplies all the tokens to Aave */
        else {
            supplyBalanceInOf[_poolTokenAddress][msg.sender].onPool += _amount
                .wadToRay()
                .rayDiv(normalizedIncome)
                .rayToWad(); // Scaled Balance
            _supplyERC20ToAave(_poolTokenAddress, _amount); // Revert on error
        }

        _updateSupplierList(_poolTokenAddress, msg.sender);
        emit Supplied(msg.sender, _poolTokenAddress, _amount);
    }

    /** @dev Borrows ERC20 tokens.
     *  @param _poolTokenAddress The address of the markets the user wants to enter.
     *  @param _amount The amount to borrow in ERC20 tokens.
     */
    function borrow(address _poolTokenAddress, uint256 _amount)
        external
        nonReentrant
        isMarketCreated(_poolTokenAddress)
        isAboveThreshold(_poolTokenAddress, _amount)
    {
        _handleMembership(_poolTokenAddress, msg.sender);
        _checkAccountLiquidity(msg.sender, _poolTokenAddress, 0, _amount);
        IAToken poolToken = IAToken(_poolTokenAddress);
        IERC20 erc20Token = IERC20(poolToken.UNDERLYING_ASSET_ADDRESS());
        // No need to update p2pUnitExchangeRate here as it's done in `_checkAccountLiquidity`
        uint256 p2pExchangeRate = marketsManagerForAave.p2pUnitExchangeRate(_poolTokenAddress);

        /* CASE 1: Some suppliers are waiting on Aave, Morpho matches the borrower in P2P with them */
        if (suppliersOnPool[_poolTokenAddress].isNotEmpty()) {
            uint256 remainingToBorrowOnAave = _matchSuppliers(_poolTokenAddress, _amount); // In underlying
            uint256 matched = _amount - remainingToBorrowOnAave;

            if (matched > 0) {
                borrowBalanceInOf[_poolTokenAddress][msg.sender].inP2P += matched
                    .wadToRay()
                    .rayDiv(p2pExchangeRate)
                    .rayToWad(); // In p2pUnit
            }

            /* If there aren't enough suppliers waiting on Aave to match all the tokens borrowed, the rest is borrowed from Aave */
            if (remainingToBorrowOnAave > 0) {
                _unmatchTheSupplier(msg.sender); // Before borrowing on Aave, we put all the collateral of the borrower on Aave (cf Liquidation Invariant in docs)
                lendingPool.borrow(
                    address(erc20Token),
                    remainingToBorrowOnAave,
                    2,
                    0,
                    address(this)
                );
                borrowBalanceInOf[_poolTokenAddress][msg.sender].onPool += remainingToBorrowOnAave
                    .wadToRay()
                    .rayDiv(lendingPool.getReserveNormalizedVariableDebt(address(erc20Token)))
                    .rayToWad(); // In adUnit
            }
        }
        /* CASE 2: There aren't any borrowers waiting on Aave, Morpho borrows all the tokens from Aave */
        else {
            _unmatchTheSupplier(msg.sender); // Before borrowing on Aave, we put all the collateral of the borrower on Aave (cf Liquidation Invariant in docs)
            lendingPool.borrow(address(erc20Token), _amount, 2, 0, address(this));
            borrowBalanceInOf[_poolTokenAddress][msg.sender].onPool += _amount
                .wadToRay()
                .rayDiv(lendingPool.getReserveNormalizedVariableDebt(address(erc20Token)))
                .rayToWad(); // In adUnit
        }

        _updateBorrowerList(_poolTokenAddress, msg.sender);
        erc20Token.safeTransfer(msg.sender, _amount);
        emit Borrowed(msg.sender, _poolTokenAddress, _amount);
    }

    /** @dev Withdraws ERC20 tokens from supply.
     *  @param _poolTokenAddress The address of the market the user wants to interact with.
     *  @param _amount The amount in tokens to withdraw from supply.
     */
    function withdraw(address _poolTokenAddress, uint256 _amount) external nonReentrant {
        _withdraw(_poolTokenAddress, _amount, msg.sender, msg.sender);
    }

    /** @dev Repays debt of the user.
     *  @dev `msg.sender` must have approved Morpho's contract to spend the underlying `_amount`.
     *  @param _poolTokenAddress The address of the market the user wants to interact with.
     *  @param _amount The amount in ERC20 tokens to repay.
     */
    function repay(address _poolTokenAddress, uint256 _amount) external nonReentrant {
        _repay(_poolTokenAddress, msg.sender, _amount);
    }

    /** @dev Allows someone to liquidate a position.
     *  @param _poolTokenBorrowedAddress The address of the debt token the liquidator wants to repay.
     *  @param _poolTokenCollateralAddress The address of the collateral the liquidator wants to seize.
     *  @param _borrower The address of the borrower to liquidate.
     *  @param _amount The amount to repay in ERC20 tokens.
     */
    function liquidate(
        address _poolTokenBorrowedAddress,
        address _poolTokenCollateralAddress,
        address _borrower,
        uint256 _amount
    ) external nonReentrant {
        LiquidateVars memory vars;
        (vars.debtValue, vars.maxDebtValue, ) = _getUserHypotheticalBalanceStates(
            _borrower,
            address(0),
            0,
            0
        );
        require(vars.debtValue > vars.maxDebtValue, "liquidate:debt-value<=max");
        IAToken poolTokenBorrowed = IAToken(_poolTokenBorrowedAddress);
        IAToken poolTokenCollateral = IAToken(_poolTokenCollateralAddress);
        vars.tokenBorrowedAddress = poolTokenBorrowed.UNDERLYING_ASSET_ADDRESS();
        vars.tokenCollateralAddress = poolTokenCollateral.UNDERLYING_ASSET_ADDRESS();
        vars.borrowBalance =
            borrowBalanceInOf[_poolTokenBorrowedAddress][_borrower]
                .onPool
                .wadToRay()
                .rayMul(lendingPool.getReserveNormalizedVariableDebt(vars.tokenBorrowedAddress))
                .wadToRay() +
            borrowBalanceInOf[_poolTokenBorrowedAddress][_borrower]
                .inP2P
                .wadToRay()
                .rayMul(marketsManagerForAave.p2pUnitExchangeRate(_poolTokenBorrowedAddress))
                .rayToWad();
        require(
            _amount <= vars.borrowBalance.mul(LIQUIDATION_CLOSE_FACTOR_PERCENT).div(10000),
            "liquidate:amount>allowed"
        );

        vars.oracle = IPriceOracleGetter(addressesProvider.getPriceOracle());
        _repay(_poolTokenBorrowedAddress, _borrower, _amount);

        // Calculate the amount of token to seize from collateral
        vars.collateralPrice = vars.oracle.getAssetPrice(vars.tokenCollateralAddress); // In ETH
        vars.borrowedPrice = vars.oracle.getAssetPrice(vars.tokenBorrowedAddress); // In ETH
        (vars.collateralReserveDecimals, , , vars.liquidationBonus, , , , , , ) = dataProvider
            .getReserveConfigurationData(vars.tokenCollateralAddress);
        (vars.borrowedReserveDecimals, , , , , , , , , ) = dataProvider.getReserveConfigurationData(
            vars.tokenBorrowedAddress
        );
        vars.collateralTokenUnit = 10**vars.collateralReserveDecimals;
        vars.borrowedTokenUnit = 10**vars.borrowedReserveDecimals;
        vars.amountToSeize = _amount
            .mul(vars.borrowedPrice)
            .div(vars.borrowedTokenUnit)
            .mul(vars.collateralTokenUnit)
            .div(vars.collateralPrice)
            .mul(vars.liquidationBonus)
            .div(10000);
        vars.normalizedIncome = lendingPool.getReserveNormalizedIncome(vars.tokenCollateralAddress);
        vars.totalCollateral =
            supplyBalanceInOf[_poolTokenCollateralAddress][_borrower]
                .onPool
                .wadToRay()
                .rayMul(vars.normalizedIncome)
                .rayToWad() +
            supplyBalanceInOf[_poolTokenCollateralAddress][_borrower]
                .inP2P
                .wadToRay()
                .rayMul(
                    marketsManagerForAave.updateP2PUnitExchangeRate(_poolTokenCollateralAddress)
                )
                .rayToWad();
        require(vars.amountToSeize <= vars.totalCollateral, "liquidate:to-seize>collateral");

        _withdraw(_poolTokenCollateralAddress, vars.amountToSeize, _borrower, msg.sender);
    }

    /* Internal */

    /** @dev Withdraws ERC20 tokens from supply.
     *  @param _poolTokenAddress The address of the market the user wants to interact with.
     *  @param _amount The amount in tokens to withdraw from supply.
     *  @param _holder the user to whom Morpho will withdraw the supply.
     *  @param _receiver The address of the user that will receive the tokens.
     */
    function _withdraw(
        address _poolTokenAddress,
        uint256 _amount,
        address _holder,
        address _receiver
    ) internal isMarketCreated(_poolTokenAddress) {
        require(_amount > 0, "_withdraw:amount=0");
        _checkAccountLiquidity(_holder, _poolTokenAddress, _amount, 0);
        IAToken poolToken = IAToken(_poolTokenAddress);
        IERC20 erc20Token = IERC20(poolToken.UNDERLYING_ASSET_ADDRESS());
        uint256 normalizedIncome = lendingPool.getReserveNormalizedIncome(address(erc20Token));
        uint256 remainingToWithdraw = _amount;

        /* If user has some tokens waiting on Aave */
        if (supplyBalanceInOf[_poolTokenAddress][_holder].onPool > 0) {
            uint256 amountOnAaveInUnderlying = supplyBalanceInOf[_poolTokenAddress][_holder]
                .onPool
                .wadToRay()
                .rayMul(normalizedIncome)
                .rayToWad();
            /* CASE 1: User withdraws less than his Aave supply balance */
            if (_amount <= amountOnAaveInUnderlying) {
                _withdrawERC20FromAave(_poolTokenAddress, _amount); // Revert on error
                supplyBalanceInOf[_poolTokenAddress][_holder].onPool -= _amount
                    .wadToRay()
                    .rayDiv(normalizedIncome)
                    .rayToWad(); // In poolToken
                remainingToWithdraw = 0; // In underlying
            }
            /* CASE 2: User withdraws more than his Aave supply balance */
            else {
                _withdrawERC20FromAave(_poolTokenAddress, amountOnAaveInUnderlying); // Revert on error
                supplyBalanceInOf[_poolTokenAddress][_holder].onPool = 0;
                remainingToWithdraw = _amount - amountOnAaveInUnderlying; // In underlying
            }
        }

        /* If there remains some tokens to withdraw (CASE 2), Morpho breaks credit lines and repair them either with other users or with Aave itself */
        if (remainingToWithdraw > 0) {
            uint256 p2pExchangeRate = marketsManagerForAave.p2pUnitExchangeRate(_poolTokenAddress);
            uint256 aTokenContractBalance = poolToken.balanceOf(address(this));
            /* CASE 1: Other suppliers have enough tokens on Aave to compensate user's position*/
            if (remainingToWithdraw <= aTokenContractBalance) {
                require(
                    _matchSuppliers(_poolTokenAddress, remainingToWithdraw) == 0,
                    "_withdraw:_matchSuppliers!=0"
                );
                supplyBalanceInOf[_poolTokenAddress][_holder].inP2P -= remainingToWithdraw
                    .wadToRay()
                    .rayDiv(p2pExchangeRate)
                    .rayToWad(); // In p2pUnit
            }
            /* CASE 2: Other suppliers don't have enough tokens on Aave. Such scenario is called the Hard-Withdraw */
            else {
                uint256 remaining = _matchSuppliers(_poolTokenAddress, aTokenContractBalance);
                supplyBalanceInOf[_poolTokenAddress][_holder].inP2P -= remainingToWithdraw
                    .wadToRay()
                    .rayDiv(p2pExchangeRate)
                    .rayToWad(); // In p2pUnit
                remainingToWithdraw -= remaining;
                require(
                    _unmatchBorrowers(_poolTokenAddress, remainingToWithdraw) == 0, // We break some P2P credit lines the user had with borrowers and fallback on Aave.
                    "_withdraw:_unmatchBorrowers!=0"
                );
            }
        }

        _updateSupplierList(_poolTokenAddress, _holder);
        erc20Token.safeTransfer(_receiver, _amount);
        emit Withdrawn(_holder, _poolTokenAddress, _amount);
    }

    /** @dev Implements repay logic.
     *  @dev `msg.sender` must have approved this contract to spend the underlying `_amount`.
     *  @param _poolTokenAddress The address of the market the user wants to interact with.
     *  @param _borrower The address of the `_borrower` to repay the borrow.
     *  @param _amount The amount of ERC20 tokens to repay.
     */
    function _repay(
        address _poolTokenAddress,
        address _borrower,
        uint256 _amount
    ) internal isMarketCreated(_poolTokenAddress) {
        IAToken poolToken = IAToken(_poolTokenAddress);
        IERC20 erc20Token = IERC20(poolToken.UNDERLYING_ASSET_ADDRESS());
        erc20Token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 remainingToRepay = _amount;

        /* If user is borrowing tokens on Aave */
        if (borrowBalanceInOf[_poolTokenAddress][_borrower].onPool > 0) {
            uint256 normalizedVariableDebt = lendingPool.getReserveNormalizedVariableDebt(
                address(erc20Token)
            );
            uint256 onAaveInUnderlying = borrowBalanceInOf[_poolTokenAddress][_borrower]
                .onPool
                .wadToRay()
                .rayMul(normalizedVariableDebt)
                .rayToWad();
            /* CASE 1: User repays less than his Aave borrow balance */
            if (_amount <= onAaveInUnderlying) {
                erc20Token.safeApprove(address(lendingPool), _amount);
                lendingPool.repay(address(erc20Token), _amount, 2, address(this));
                borrowBalanceInOf[_poolTokenAddress][_borrower].onPool -= _amount
                    .wadToRay()
                    .rayDiv(normalizedVariableDebt)
                    .rayToWad(); // In adUnit
                remainingToRepay = 0;
            }
            /* CASE 2: User repays more than his Aave borrow balance */
            else {
                erc20Token.safeApprove(address(lendingPool), onAaveInUnderlying);
                lendingPool.repay(address(erc20Token), onAaveInUnderlying, 2, address(this));
                borrowBalanceInOf[_poolTokenAddress][_borrower].onPool = 0;
                remainingToRepay -= onAaveInUnderlying; // In underlying
            }
        }

        /* If there remains some tokens to repay (CASE 2), Morpho breaks credit lines and repair them either with other users or with Aave itself */
        if (remainingToRepay > 0) {
            DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(
                address(erc20Token)
            );
            IVariableDebtToken variableDebtToken = IVariableDebtToken(
                reserveData.variableDebtTokenAddress
            );
            uint256 p2pExchangeRate = marketsManagerForAave.updateP2PUnitExchangeRate(
                _poolTokenAddress
            );
            uint256 contractBorrowBalanceOnAave = variableDebtToken.scaledBalanceOf(address(this));
            /* CASE 1: Other borrowers are borrowing enough on Aave to compensate user's position */
            if (remainingToRepay <= contractBorrowBalanceOnAave) {
                _matchBorrowers(_poolTokenAddress, remainingToRepay);
                borrowBalanceInOf[_poolTokenAddress][_borrower].inP2P -= remainingToRepay
                    .wadToRay()
                    .rayDiv(p2pExchangeRate)
                    .rayToWad();
            }
            /* CASE 2: Other borrowers aren't borrowing enough on Aave to compensate user's position */
            else {
                _matchBorrowers(_poolTokenAddress, contractBorrowBalanceOnAave);
                borrowBalanceInOf[_poolTokenAddress][_borrower].inP2P -= remainingToRepay
                    .wadToRay()
                    .rayDiv(p2pExchangeRate)
                    .rayToWad(); // In p2pUnit
                remainingToRepay -= contractBorrowBalanceOnAave;
                require(
                    _unmatchSuppliers(_poolTokenAddress, remainingToRepay) == 0, // We break some P2P credit lines the user had with suppliers and fallback on Aave.
                    "_repay:_unmatchSuppliers!=0"
                );
            }
        }

        _updateBorrowerList(_poolTokenAddress, _borrower);
        emit Repaid(_borrower, _poolTokenAddress, _amount);
    }

    /** @dev Supplies ERC20 tokens to Aave.
     *  @param _poolTokenAddress The address of the market the user wants to interact with.
     *  @param _amount The amount in ERC20 tokens to supply.
     */
    function _supplyERC20ToAave(address _poolTokenAddress, uint256 _amount) internal {
        IAToken poolToken = IAToken(_poolTokenAddress);
        IERC20 erc20Token = IERC20(poolToken.UNDERLYING_ASSET_ADDRESS());
        erc20Token.safeApprove(address(lendingPool), _amount);
        lendingPool.deposit(address(erc20Token), _amount, address(this), 0);
        lendingPool.setUserUseReserveAsCollateral(address(erc20Token), true);
    }

    /** @dev Withdraws ERC20 tokens from Aave.
     *  @param _poolTokenAddress The address of the market the user wants to interact with.
     *  @param _amount The amount of tokens to be withdrawn.
     */
    function _withdrawERC20FromAave(address _poolTokenAddress, uint256 _amount) internal {
        IAToken poolToken = IAToken(_poolTokenAddress);
        lendingPool.withdraw(poolToken.UNDERLYING_ASSET_ADDRESS(), _amount, address(this));
    }

    /** @dev Finds liquidity on Aave and matches it in P2P.
     *  @dev Note: p2pUnitExchangeRate must have been updated before calling this function.
     *  @param _poolTokenAddress The address of the market on which Morpho want to move users.
     *  @param _amount The amount to search for in underlying.
     *  @return remainingToMatch The remaining liquidity to search for in underlying.
     */
    function _matchSuppliers(address _poolTokenAddress, uint256 _amount)
        internal
        returns (uint256 remainingToMatch)
    {
        MatchSuppliersVars memory vars;
        IAToken poolToken = IAToken(_poolTokenAddress);
        remainingToMatch = _amount; // In underlying
        uint256 normalizedIncome = lendingPool.getReserveNormalizedIncome(
            poolToken.UNDERLYING_ASSET_ADDRESS()
        );
        vars.highestValue = suppliersOnPool[_poolTokenAddress].last();

        vars.highestValueSeen; // Allow us to store the previous
        while (remainingToMatch > 0 && vars.highestValue != 0) {
            // Loop on the keys (addresses) sharing the same value
            vars.numberOfKeysAtValue = suppliersOnPool[_poolTokenAddress].getNumberOfKeysAtValue(
                vars.highestValue
            );
            uint256 indexOfSupplier = 0;
            // Check that there are is still a supplier having no debt on Creams is
            while (remainingToMatch > 0 && vars.numberOfKeysAtValue - indexOfSupplier > 0) {
                address account = suppliersOnPool[_poolTokenAddress].valueKeyAtIndex(
                    vars.highestValue,
                    indexOfSupplier
                );
                // Check if this user is not borrowing on Aave (cf Liquidation Invariant in docs)
                if (!_hasDebtOnAave(account)) {
                    vars.onAaveInUnderlying = supplyBalanceInOf[_poolTokenAddress][account]
                        .onPool
                        .wadToRay()
                        .rayMul(normalizedIncome)
                        .rayToWad();
                    uint256 toMatch = Math.min(vars.onAaveInUnderlying, remainingToMatch);
                    supplyBalanceInOf[_poolTokenAddress][account].onPool -= toMatch
                        .wadToRay()
                        .rayDiv(normalizedIncome)
                        .rayToWad();
                    remainingToMatch -= toMatch;
                    supplyBalanceInOf[_poolTokenAddress][account].inP2P += toMatch
                        .wadToRay()
                        .rayDiv(marketsManagerForAave.p2pUnitExchangeRate(_poolTokenAddress))
                        .rayToWad(); // In p2pUnit
                    _updateSupplierList(_poolTokenAddress, account);
                    vars.numberOfKeysAtValue = suppliersOnPool[_poolTokenAddress]
                        .getNumberOfKeysAtValue(vars.highestValue);
                    emit SupplierMatched(account, _poolTokenAddress, toMatch);
                } else {
                    vars.highestValueSeen = vars.highestValue;
                    indexOfSupplier++;
                }
            }
            // Update the highest value after the tree has been updated
            if (vars.highestValueSeen > 0)
                vars.highestValue = suppliersOnPool[_poolTokenAddress].prev(vars.highestValueSeen);
            else vars.highestValue = suppliersOnPool[_poolTokenAddress].last();
        }
        // Withdraw from Aave
        uint256 toWithdraw = _amount - remainingToMatch;
        if (toWithdraw > 0) _withdrawERC20FromAave(_poolTokenAddress, _amount - remainingToMatch);
    }

    /** @dev Finds liquidity in peer-to-peer and unmatches it to reconnect Aave.
     *  @dev Note: p2pUnitExchangeRate must have been updated before calling this function.
     *  @param _poolTokenAddress The address of the market on which Morpho want to move users.
     *  @param _amount The amount to search for in underlying.
     *  @return remainingToUnmatch The amount remaining to munmatchatch in underlying.
     */
    function _unmatchSuppliers(address _poolTokenAddress, uint256 _amount)
        internal
        returns (uint256 remainingToUnmatch)
    {
        IAToken poolToken = IAToken(_poolTokenAddress);
        uint256 normalizedIncome = lendingPool.getReserveNormalizedIncome(
            poolToken.UNDERLYING_ASSET_ADDRESS()
        );
        remainingToUnmatch = _amount; // In underlying
        uint256 p2pExchangeRate = marketsManagerForAave.p2pUnitExchangeRate(_poolTokenAddress);
        uint256 highestValue = suppliersInP2P[_poolTokenAddress].last();

        while (remainingToUnmatch > 0 && highestValue != 0) {
            while (
                remainingToUnmatch > 0 &&
                suppliersInP2P[_poolTokenAddress].getNumberOfKeysAtValue(highestValue) > 0
            ) {
                address account = suppliersInP2P[_poolTokenAddress].valueKeyAtIndex(
                    highestValue,
                    0
                );
                uint256 inP2P = supplyBalanceInOf[_poolTokenAddress][account].inP2P; // In poolToken
                uint256 toUnmatch = Math.min(inP2P.mul(p2pExchangeRate), remainingToUnmatch); // In underlying
                remainingToUnmatch -= toUnmatch;
                supplyBalanceInOf[_poolTokenAddress][account].onPool += toUnmatch
                    .wadToRay()
                    .rayDiv(normalizedIncome)
                    .rayToWad();
                supplyBalanceInOf[_poolTokenAddress][account].inP2P -= toUnmatch
                    .wadToRay()
                    .rayDiv(p2pExchangeRate)
                    .rayToWad(); // In p2pUnit
                _updateSupplierList(_poolTokenAddress, account);
                emit SupplierUnmatched(account, _poolTokenAddress, toUnmatch);
            }
            highestValue = suppliersInP2P[_poolTokenAddress].last();
        }
        // Supply on Aave
        uint256 toSupply = _amount - remainingToUnmatch;
        if (toSupply > 0) _supplyERC20ToAave(_poolTokenAddress, _amount - remainingToUnmatch);
    }

    /** @dev Finds borrowers on Aave that match the given `_amount` and move them in P2P.
     *  @dev Note: p2pUnitExchangeRate must have been updated before calling this function.
     *  @param _poolTokenAddress The address of the market on which Morpho wants to move users.
     *  @param _amount The amount to match in underlying.
     *  @return remainingToMatch The amount remaining to match in underlying.
     */
    function _matchBorrowers(address _poolTokenAddress, uint256 _amount)
        internal
        returns (uint256 remainingToMatch)
    {
        IAToken poolToken = IAToken(_poolTokenAddress);
        IERC20 erc20Token = IERC20(poolToken.UNDERLYING_ASSET_ADDRESS());
        remainingToMatch = _amount;
        uint256 normalizedVariableDebt = lendingPool.getReserveNormalizedVariableDebt(
            address(erc20Token)
        );
        uint256 p2pExchangeRate = marketsManagerForAave.p2pUnitExchangeRate(_poolTokenAddress);
        uint256 highestValue = borrowersOnPool[_poolTokenAddress].last();

        while (remainingToMatch > 0 && highestValue != 0) {
            while (
                remainingToMatch > 0 &&
                borrowersOnPool[_poolTokenAddress].getNumberOfKeysAtValue(highestValue) > 0
            ) {
                address account = borrowersOnPool[_poolTokenAddress].valueKeyAtIndex(
                    highestValue,
                    0
                );
                uint256 onAaveInUnderlying = borrowBalanceInOf[_poolTokenAddress][account]
                    .onPool
                    .wadToRay()
                    .rayMul(normalizedVariableDebt)
                    .rayToWad();
                uint256 toMatch = Math.min(onAaveInUnderlying, remainingToMatch);
                borrowBalanceInOf[_poolTokenAddress][account].onPool -= toMatch
                    .wadToRay()
                    .rayDiv(normalizedVariableDebt)
                    .rayToWad();
                remainingToMatch -= toMatch;
                borrowBalanceInOf[_poolTokenAddress][account].inP2P += toMatch
                    .wadToRay()
                    .rayDiv(p2pExchangeRate)
                    .rayToWad();
                _updateBorrowerList(_poolTokenAddress, account);
                emit BorrowerMatched(account, _poolTokenAddress, toMatch);
            }
            highestValue = borrowersOnPool[_poolTokenAddress].last();
        }
        // Repay Aave
        uint256 toRepay = _amount - remainingToMatch;
        if (toRepay > 0) {
            erc20Token.safeApprove(address(lendingPool), toRepay);
            lendingPool.repay(address(erc20Token), toRepay, 2, address(this));
        }
    }

    /** @dev Finds borrowers in peer-to-peer that match the given `_amount` and move them to Aave.
     *  @dev Note: p2pUnitExchangeRate must have been updated before calling this function.
     *  @param _poolTokenAddress The address of the market on which Morpho wants to move users.
     *  @param _amount The amount to match in underlying.
     *  @return remainingToUnmatch The amount remaining to munmatchatch in underlying.
     */
    function _unmatchBorrowers(address _poolTokenAddress, uint256 _amount)
        internal
        returns (uint256 remainingToUnmatch)
    {
        IAToken poolToken = IAToken(_poolTokenAddress);
        IERC20 erc20Token = IERC20(poolToken.UNDERLYING_ASSET_ADDRESS());
        remainingToUnmatch = _amount;
        uint256 p2pExchangeRate = marketsManagerForAave.p2pUnitExchangeRate(_poolTokenAddress);
        uint256 normalizedVariableDebt = lendingPool.getReserveNormalizedVariableDebt(
            address(erc20Token)
        );
        uint256 highestValue = borrowersInP2P[_poolTokenAddress].last();

        while (remainingToUnmatch > 0 && highestValue != 0) {
            while (
                remainingToUnmatch > 0 &&
                borrowersInP2P[_poolTokenAddress].getNumberOfKeysAtValue(highestValue) > 0
            ) {
                address account = borrowersInP2P[_poolTokenAddress].valueKeyAtIndex(
                    highestValue,
                    0
                );
                uint256 inP2P = borrowBalanceInOf[_poolTokenAddress][account].inP2P;
                _unmatchTheSupplier(account); // Before borrowing on Aave, we put all the collateral of the borrower on Aave (cf Liquidation Invariant in docs)
                uint256 toUnmatch = Math.min(inP2P.mul(p2pExchangeRate), remainingToUnmatch); // In underlying
                remainingToUnmatch -= toUnmatch;
                borrowBalanceInOf[_poolTokenAddress][account].onPool += toUnmatch
                    .wadToRay()
                    .rayDiv(normalizedVariableDebt)
                    .rayToWad();
                borrowBalanceInOf[_poolTokenAddress][account].inP2P -= toUnmatch
                    .wadToRay()
                    .rayDiv(p2pExchangeRate)
                    .rayToWad();
                _updateBorrowerList(_poolTokenAddress, account);
                emit BorrowerUnmatched(account, _poolTokenAddress, toUnmatch);
            }
            highestValue = borrowersInP2P[_poolTokenAddress].last();
        }
        // Borrow on Aave
        lendingPool.borrow(address(erc20Token), _amount - remainingToUnmatch, 2, 0, address(this));
    }

    /**
     * @dev Moves supply balance of an account from Morpho to Aave.
     * @param _account The address of the account to move balance.
     */
    function _unmatchTheSupplier(address _account) internal {
        for (uint256 i; i < enteredMarkets[_account].length; i++) {
            address poolTokenEntered = enteredMarkets[_account][i];
            uint256 normalizedIncome = lendingPool.getReserveNormalizedIncome(
                IAToken(poolTokenEntered).UNDERLYING_ASSET_ADDRESS()
            );
            uint256 inP2P = supplyBalanceInOf[poolTokenEntered][_account].inP2P;

            if (inP2P > 0) {
                uint256 p2pExchangeRate = marketsManagerForAave.p2pUnitExchangeRate(
                    poolTokenEntered
                );
                uint256 inP2PInUnderlying = inP2P.wadToRay().rayMul(p2pExchangeRate).rayToWad();
                supplyBalanceInOf[poolTokenEntered][_account].onPool += inP2PInUnderlying
                    .wadToRay()
                    .rayDiv(normalizedIncome)
                    .rayToWad();
                supplyBalanceInOf[poolTokenEntered][_account].inP2P -= inP2PInUnderlying
                    .wadToRay()
                    .rayDiv(p2pExchangeRate)
                    .rayToWad(); // In p2pUnit
                _unmatchBorrowers(poolTokenEntered, inP2PInUnderlying);
                _updateSupplierList(poolTokenEntered, _account);
                // Supply to Aave
                _supplyERC20ToAave(poolTokenEntered, inP2PInUnderlying);
                emit SupplierUnmatched(_account, poolTokenEntered, inP2PInUnderlying);
            }
        }
    }

    /**
     * @dev Enters the user into the market if he is not already there.
     * @param _account The address of the account to update.
     * @param _poolTokenAddress The address of the market to check.
     */
    function _handleMembership(address _poolTokenAddress, address _account) internal {
        if (!accountMembership[_poolTokenAddress][_account]) {
            accountMembership[_poolTokenAddress][_account] = true;
            enteredMarkets[_account].push(_poolTokenAddress);
        }
    }

    /** @dev Checks whether the user can borrow/withdraw or not.
     *  @param _account The user to determine liquidity for.
     *  @param _poolTokenAddress The market to hypothetically withdraw/borrow in.
     *  @param _withdrawnAmount The number of tokens to hypothetically withdraw.
     *  @param _borrowedAmount The amount of underlying to hypothetically borrow.
     */
    function _checkAccountLiquidity(
        address _account,
        address _poolTokenAddress,
        uint256 _withdrawnAmount,
        uint256 _borrowedAmount
    ) internal {
        (uint256 debtValue, uint256 maxDebtValue, ) = _getUserHypotheticalBalanceStates(
            _account,
            _poolTokenAddress,
            _withdrawnAmount,
            _borrowedAmount
        );
        require(debtValue < maxDebtValue, "_checkAccountLiquidity:debt-value>max");
    }

    /** @dev Returns the debt value, max debt value and collateral value of a given user.
     *  @param _account The user to determine liquidity for.
     *  @param _poolTokenAddress The market to hypothetically withdraw/borrow in.
     *  @param _withdrawnAmount The number of tokens to hypothetically withdraw.
     *  @param _borrowedAmount The amount of underlying to hypothetically borrow.
     *  @return (debtValue, maxDebtValue collateralValue).
     */
    function _getUserHypotheticalBalanceStates(
        address _account,
        address _poolTokenAddress,
        uint256 _withdrawnAmount,
        uint256 _borrowedAmount
    )
        internal
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        // Avoid stack too deep error
        BalanceStateVars memory vars;
        vars.oracle = IPriceOracleGetter(addressesProvider.getPriceOracle());

        for (uint256 i; i < enteredMarkets[_account].length; i++) {
            vars.poolTokenEntered = enteredMarkets[_account][i];
            vars.p2pExchangeRate = marketsManagerForAave.updateP2PUnitExchangeRate(
                vars.poolTokenEntered
            );
            // Calculation of the current debt (in underlying)
            vars.underlyingAddress = IAToken(vars.poolTokenEntered).UNDERLYING_ASSET_ADDRESS();
            vars.normalizedVariableDebt = lendingPool.getReserveNormalizedVariableDebt(
                vars.underlyingAddress
            );
            vars.debtToAdd =
                borrowBalanceInOf[vars.poolTokenEntered][_account]
                    .onPool
                    .wadToRay()
                    .rayMul(vars.normalizedVariableDebt)
                    .rayToWad() +
                borrowBalanceInOf[vars.poolTokenEntered][_account].inP2P.mul(vars.p2pExchangeRate);
            // Calculation of the current collateral (in underlying)
            vars.normalizedIncome = lendingPool.getReserveNormalizedIncome(vars.underlyingAddress);
            vars.collateralToAdd =
                supplyBalanceInOf[vars.poolTokenEntered][_account]
                    .onPool
                    .wadToRay()
                    .rayMul(vars.normalizedIncome)
                    .rayToWad() +
                supplyBalanceInOf[vars.poolTokenEntered][_account].inP2P.mul(vars.p2pExchangeRate);
            vars.underlyingPrice = vars.oracle.getAssetPrice(vars.underlyingAddress); // In ETH

            (vars.reserveDecimals, , vars.liquidationThreshold, , , , , , , ) = dataProvider
                .getReserveConfigurationData(vars.underlyingAddress);
            vars.tokenUnit = 10**vars.reserveDecimals;
            if (_poolTokenAddress == vars.poolTokenEntered) {
                vars.debtToAdd += _borrowedAmount;
                vars.redeemedValue = _withdrawnAmount.mul(vars.underlyingPrice).div(vars.tokenUnit);
            }
            // Conversion of the collateral to ETH
            vars.collateralToAdd = vars.collateralToAdd.mul(vars.underlyingPrice).div(
                vars.tokenUnit
            );
            // Add the debt in this market to the global debt (in ETH)
            vars.debtValue += vars.debtToAdd.mul(vars.underlyingPrice).div(vars.tokenUnit);
            // Add the collateral value in this asset to the global collateral value (in ETH)
            vars.collateralValue += vars.collateralToAdd;
            // Add the max debt value allowed by the collateral in this asset to the global max debt value (in ETH)
            vars.maxDebtValue += vars.collateralToAdd.mul(vars.liquidationThreshold).div(10000);
        }

        vars.collateralValue -= vars.redeemedValue;

        return (vars.debtValue, vars.maxDebtValue, vars.collateralValue);
    }

    /** @dev Updates borrowers tree with the new balances of a given account.
     *  @param _poolTokenAddress The address of the market on which Morpho want to update the borrower lists.
     *  @param _account The address of the borrower to move.
     */
    function _updateBorrowerList(address _poolTokenAddress, address _account) internal {
        if (borrowersOnPool[_poolTokenAddress].keyExists(_account))
            borrowersOnPool[_poolTokenAddress].remove(_account);
        if (borrowersInP2P[_poolTokenAddress].keyExists(_account))
            borrowersInP2P[_poolTokenAddress].remove(_account);
        uint256 onPool = borrowBalanceInOf[_poolTokenAddress][_account].onPool;
        if (onPool > 0) borrowersOnPool[_poolTokenAddress].insert(_account, onPool);
        uint256 inP2P = borrowBalanceInOf[_poolTokenAddress][_account].inP2P;
        if (inP2P > 0) borrowersInP2P[_poolTokenAddress].insert(_account, inP2P);
    }

    /** @dev Updates suppliers tree with the new balances of a given account.
     *  @param _poolTokenAddress The address of the market on which Morpho want to update the supplier lists.
     *  @param _account The address of the supplier to move.
     */
    function _updateSupplierList(address _poolTokenAddress, address _account) internal {
        if (suppliersOnPool[_poolTokenAddress].keyExists(_account))
            suppliersOnPool[_poolTokenAddress].remove(_account);
        if (suppliersInP2P[_poolTokenAddress].keyExists(_account))
            suppliersInP2P[_poolTokenAddress].remove(_account);
        uint256 onPool = supplyBalanceInOf[_poolTokenAddress][_account].onPool;
        if (onPool > 0) suppliersOnPool[_poolTokenAddress].insert(_account, onPool);
        uint256 inP2P = supplyBalanceInOf[_poolTokenAddress][_account].inP2P;
        if (inP2P > 0) suppliersInP2P[_poolTokenAddress].insert(_account, inP2P);
    }

    function _hasDebtOnAave(address _account) internal view returns (bool) {
        for (uint256 i; i < enteredMarkets[_account].length; i++) {
            if (borrowBalanceInOf[enteredMarkets[_account][i]][_account].onPool > 0) return true;
        }
        return false;
    }
}
