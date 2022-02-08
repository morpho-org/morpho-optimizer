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
    uint256 constant INITIAL_BALANCE = 1_000_000;

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

    function setUp() public {
        marketsManager = new MarketsManagerForAave(lendingPoolAddressesProviderAddress);
        positionsManager = new PositionsManagerForAave(
            address(marketsManager),
            lendingPoolAddressesProviderAddress
        );

        treasuryVault = new User(positionsManager, marketsManager, rewardsManager, lendingPool);

        fakePositionsManager = new PositionsManagerForAave(
            address(marketsManager),
            lendingPoolAddressesProviderAddress
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
        marketsManager.updateLendingPool();

        // !!! WARNING !!!
        // All tokens must also be added to the pools array, for the correct behavior of TestLiquidate::createAndSetCustomPriceOracle.
        marketsManager.createMarket(aDai, WAD);
        pools.push(aDai);
        marketsManager.createMarket(aUsdc, to6Decimals(WAD));
        pools.push(aUsdc);
        marketsManager.createMarket(aWbtc, 10**4);
        pools.push(aWbtc);
        marketsManager.createMarket(aUsdt, to6Decimals(WAD));
        pools.push(aUsdt);
        marketsManager.createMarket(aWmatic, WAD);
        pools.push(aWmatic);

        for (uint256 i = 0; i < 3; i++) {
            suppliers.push(new User(positionsManager, marketsManager, rewardsManager, lendingPool));

            writeBalanceOf(address(suppliers[i]), dai, INITIAL_BALANCE * WAD);
            writeBalanceOf(address(suppliers[i]), usdc, INITIAL_BALANCE * 1e6);
        }
        supplier1 = suppliers[0];
        supplier2 = suppliers[1];
        supplier3 = suppliers[2];

        for (uint256 i = 0; i < 3; i++) {
            borrowers.push(new User(positionsManager, marketsManager, rewardsManager, lendingPool));

            writeBalanceOf(address(borrowers[i]), dai, INITIAL_BALANCE * WAD);
            writeBalanceOf(address(borrowers[i]), usdc, INITIAL_BALANCE * 1e6);
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
            borrowers.push(new User(positionsManager, marketsManager, rewardsManager, lendingPool));
            writeBalanceOf(address(borrowers[borrowers.length - 1]), dai, INITIAL_BALANCE * WAD);
            writeBalanceOf(address(borrowers[borrowers.length - 1]), usdc, INITIAL_BALANCE * 1e6);

            suppliers.push(new User(positionsManager, marketsManager, rewardsManager, lendingPool));
            writeBalanceOf(address(suppliers[suppliers.length - 1]), dai, INITIAL_BALANCE * WAD);
            writeBalanceOf(address(suppliers[suppliers.length - 1]), usdc, INITIAL_BALANCE * 1e6);
        }
    }
}
