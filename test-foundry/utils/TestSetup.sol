// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.7;

import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@contracts/aave/interfaces/aave/IPriceOracleGetter.sol";

import "@contracts/aave/PositionsManagerForAave.sol";
import "@contracts/aave/MarketsManagerForAave.sol";
import "@contracts/aave/RewardsManager.sol";
import "@contracts/aave/test/SimplePriceOracle.sol";
import "@config/Config.sol";
import "./HEVM.sol";
import "./Utils.sol";
import "./User.sol";

contract TestSetup is Config, Utils {
    using WadRayMath for uint256;

    uint256 public constant MAX_BASIS_POINTS = 10000;

    HEVM public hevm = HEVM(HEVM_ADDRESS);

    PositionsManagerForAave internal positionsManager;
    PositionsManagerForAave internal fakePositionsManager;
    MarketsManagerForAave internal marketsManager;
    RewardsManager internal rewardsManager;

    ILendingPoolAddressesProvider public lendingPoolAddressesProvider;
    ILendingPool public lendingPool;
    IProtocolDataProvider public protocolDataProvider;
    IPriceOracleGetter public oracle;

    User public supplier1;
    User public supplier2;
    User public supplier3;
    User[] public suppliers;

    User public borrower1;
    User public borrower2;
    User public borrower3;
    User[] public borrowers;
    User public treasuryVault;

    address[] public pools;
    address[] public underlyings;

    function setUp() public {
        PositionsManagerForAave.MGTC memory mgtc = PositionsManagerForAaveStorage.MGTC({
            supply: 1.5e6,
            borrow: 1.5e6,
            withdraw: 3e6,
            repay: 3e6
        });

        marketsManager = new MarketsManagerForAave(lendingPoolAddressesProviderAddress);
        positionsManager = new PositionsManagerForAave(
            address(marketsManager),
            lendingPoolAddressesProviderAddress,
            mgtc
        );

        treasuryVault = new User(positionsManager, marketsManager, rewardsManager);

        fakePositionsManager = new PositionsManagerForAave(
            address(marketsManager),
            lendingPoolAddressesProviderAddress,
            mgtc
        );

        rewardsManager = new RewardsManager(
            lendingPoolAddressesProviderAddress,
            address(positionsManager)
        );

        lendingPoolAddressesProvider = ILendingPoolAddressesProvider(
            lendingPoolAddressesProviderAddress
        );
        lendingPool = ILendingPool(lendingPoolAddressesProvider.getLendingPool());

        protocolDataProvider = IProtocolDataProvider(protocolDataProviderAddress);

        oracle = IPriceOracleGetter(lendingPoolAddressesProvider.getPriceOracle());

        marketsManager.setPositionsManager(address(positionsManager));
        positionsManager.setAaveIncentivesController(aaveIncentivesControllerAddress);

        rewardsManager.setAaveIncentivesController(aaveIncentivesControllerAddress);
        positionsManager.setTreasuryVault(address(treasuryVault));
        positionsManager.setRewardsManager(address(rewardsManager));
        marketsManager.updateAaveContracts();

        // !!! WARNING !!!
        // All tokens must also be added to the pools array, for the correct behavior of TestLiquidate::createAndSetCustomPriceOracle.
        marketsManager.createMarket(dai, WAD);
        pools.push(aDai);
        underlyings.push(dai);
        marketsManager.createMarket(usdc, to6Decimals(WAD));
        pools.push(aUsdc);
        underlyings.push(usdc);
        marketsManager.createMarket(wbtc, 10**4);
        pools.push(aWbtc);
        underlyings.push(wbtc);
        marketsManager.createMarket(usdt, to6Decimals(WAD));
        pools.push(aUsdt);
        underlyings.push(usdt);
        marketsManager.createMarket(wmatic, WAD);
        pools.push(aWmatic);
        underlyings.push(wmatic);

        for (uint256 i = 0; i < 3; i++) {
            suppliers.push(new User(positionsManager, marketsManager, rewardsManager));

            writeBalanceOf(address(suppliers[i]), dai, type(uint256).max / 2);
            writeBalanceOf(address(suppliers[i]), usdc, type(uint256).max / 2);
        }
        supplier1 = suppliers[0];
        supplier2 = suppliers[1];
        supplier3 = suppliers[2];

        for (uint256 i = 0; i < 3; i++) {
            borrowers.push(new User(positionsManager, marketsManager, rewardsManager));

            writeBalanceOf(address(borrowers[i]), dai, type(uint256).max / 2);
            writeBalanceOf(address(borrowers[i]), usdc, type(uint256).max / 2);
        }
        borrower1 = borrowers[0];
        borrower2 = borrowers[1];
        borrower3 = borrowers[2];
    }

    function writeBalanceOf(
        address who,
        address acct,
        uint256 value
    ) internal {
        hevm.store(acct, keccak256(abi.encode(who, slots[acct])), bytes32(value));
    }

    function createSigners(uint8 _nbOfSigners) internal {
        while (borrowers.length < _nbOfSigners) {
            borrowers.push(new User(positionsManager, marketsManager, rewardsManager));
            writeBalanceOf(address(borrowers[borrowers.length - 1]), dai, type(uint256).max / 2);
            writeBalanceOf(address(borrowers[borrowers.length - 1]), usdc, type(uint256).max / 2);

            suppliers.push(new User(positionsManager, marketsManager, rewardsManager));
            writeBalanceOf(address(suppliers[suppliers.length - 1]), dai, type(uint256).max / 2);
            writeBalanceOf(address(suppliers[suppliers.length - 1]), usdc, type(uint256).max / 2);
        }
    }
}
