require('dotenv').config({ path: '.env.local' });
const { utils, BigNumber } = require('ethers');
const { ethers } = require('hardhat');
const { expect } = require('chai');
const hre = require('hardhat');
const config = require('@config/polygon-config.json').polygon;
const {
  SCALE,
  underlyingToCToken,
  cTokenToUnderlying,
  underlyingToMUnit,
  mUnitToUnderlying,
  underlyingToCdUnit,
  cDUnitToUnderlying,
  removeDigitsBigNumber,
  bigNumberMin,
  to6Decimals,
  computeNewMorphoExchangeRate,
  getTokens,
} = require('./utils/helpers');

describe('CreamPositionsManager Contract', () => {
  let cUsdcToken;
  let cDaiToken;
  let cUsdtToken;
  let cMkrToken;
  let daiToken;
  let usdtToken;
  let uniToken;
  let CreamPositionsManager;
  let creamPositionsManager;
  let fakeCreamPositionsManager;

  let signers;
  let owner;
  let supplier1;
  let supplier2;
  let supplier3;
  let borrower1;
  let borrower2;
  let borrower3;
  let liquidator;
  let addrs;
  let suppliers;
  let borrowers;

  let underlyingThreshold;

  beforeEach(async () => {
    // Users
    signers = await ethers.getSigners();
    [owner, supplier1, supplier2, supplier3, borrower1, borrower2, borrower3, liquidator, ...addrs] = signers;
    suppliers = [supplier1, supplier2, supplier3];
    borrowers = [borrower1, borrower2, borrower3];

    const RedBlackBinaryTree = await ethers.getContractFactory('RedBlackBinaryTree');
    const redBlackBinaryTree = await RedBlackBinaryTree.deploy();
    await redBlackBinaryTree.deployed();

    // Deploy contracts
    CompMarketsManager = await ethers.getContractFactory('CompMarketsManager');
    compMarketsManager = await CompMarketsManager.deploy(config.cream.comptroller.address);
    await compMarketsManager.deployed();

    CreamPositionsManager = await ethers.getContractFactory('CreamPositionsManager', {
      libraries: {
        RedBlackBinaryTree: redBlackBinaryTree.address,
      },
    });
    creamPositionsManager = await CreamPositionsManager.deploy(compMarketsManager.address, config.cream.comptroller.address);
    fakeCreamPositionsManager = await CreamPositionsManager.deploy(compMarketsManager.address, config.cream.comptroller.address);
    await creamPositionsManager.deployed();
    await fakeCreamPositionsManager.deployed();

    // Get contract dependencies
    const cTokenAbi = require(config.tokens.cToken.abi);
    cUsdcToken = await ethers.getContractAt(cTokenAbi, config.tokens.cUsdc.address, owner);
    cDaiToken = await ethers.getContractAt(cTokenAbi, config.tokens.cDai.address, owner);
    cUsdtToken = await ethers.getContractAt(cTokenAbi, config.tokens.cUsdt.address, owner);
    cUniToken = await ethers.getContractAt(cTokenAbi, config.tokens.cUni.address, owner);
    cMkrToken = await ethers.getContractAt(cTokenAbi, config.tokens.cMkr.address, owner); // This is in fact crLINK tokens (no crMKR on Polygon)

    comptroller = await ethers.getContractAt(require(config.cream.comptroller.abi), config.cream.comptroller.address, owner);
    compoundOracle = await ethers.getContractAt(require(config.cream.oracle.abi), comptroller.oracle(), owner);

    // Mint some ERC20
    daiToken = await getTokens('0x27f8d03b3a2196956ed754badc28d73be8830a6e', 'whale', signers, config.tokens.dai, utils.parseUnits('10000'));
    usdcToken = await getTokens('0x1a13f4ca1d028320a707d99520abfefca3998b7f', 'whale', signers, config.tokens.usdc, BigNumber.from(10).pow(10));
    usdtToken = await getTokens('0x44aaa9ebafb4557605de574d5e968589dc3a84d1', 'whale', signers, config.tokens.usdt, BigNumber.from(10).pow(10));
    uniToken = await getTokens('0xf7135272a5584eb116f5a77425118a8b4a2ddfdb', 'whale', signers, config.tokens.uni, utils.parseUnits('100'));

    underlyingThreshold = utils.parseUnits('1');

    // Create and list markets
    await compMarketsManager.connect(owner).setCompPositionsManager(creamPositionsManager.address);
    await compMarketsManager.connect(owner).createMarkets([config.tokens.cDai.address, config.tokens.cUsdc.address, config.tokens.cUsdt.address, config.tokens.cUni.address]);
    await compMarketsManager.connect(owner).listMarket(config.tokens.cDai.address);
    await compMarketsManager.connect(owner).updateThreshold(config.tokens.cUsdc.address, BigNumber.from(1).pow(6));
    await compMarketsManager.connect(owner).listMarket(config.tokens.cUsdc.address);
    await compMarketsManager.connect(owner).updateThreshold(config.tokens.cUsdt.address, BigNumber.from(1).pow(6));
    await compMarketsManager.connect(owner).listMarket(config.tokens.cUsdt.address);
    await compMarketsManager.connect(owner).listMarket(config.tokens.cUni.address);
  });

  describe('Deployment', () => {
    it('Should deploy the contract with the right values', async () => {
      // Calculate p2pBPY
      const borrowRatePerBlock = await cDaiToken.borrowRatePerBlock();
      const supplyRatePerBlock = await cDaiToken.supplyRatePerBlock();
      const expectedBPY = borrowRatePerBlock.add(supplyRatePerBlock).div(2);
      expect(await compMarketsManager.p2pBPY(config.tokens.cDai.address)).to.equal(expectedBPY);
      expect(await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address)).to.be.equal(utils.parseUnits('1'));

      // Thresholds
      underlyingThreshold = await compMarketsManager.thresholds(config.tokens.cDai.address);
      expect(underlyingThreshold).to.be.equal(utils.parseUnits('1'));
    });
  });

  describe('Governance functions', () => {
    it('Should revert when at least one of the markets in input is not a real market', async () => {
      expect(compMarketsManager.connect(owner).createMarkets([config.tokens.usdt.address])).to.be.reverted;
      expect(compMarketsManager.connect(owner).createMarkets([config.tokens.cEth.address, config.tokens.usdt.address, config.tokens.cUni.address])).to.be.reverted;
      expect(compMarketsManager.connect(owner).createMarkets([config.tokens.cEth.address])).not.be.reverted;
    });

    it('Only Owner should be able to create markets on Morpho', async () => {
      expect(compMarketsManager.connect(supplier1).createMarkets([config.tokens.cEth.address])).to.be.reverted;
      expect(compMarketsManager.connect(borrower1).createMarkets([config.tokens.cEth.address])).to.be.reverted;
      expect(compMarketsManager.connect(owner).createMarkets([config.tokens.cEth.address])).not.be.reverted;
    });

    it('Only Morpho should be able to create markets on CreamPositionsManager', async () => {
      expect(creamPositionsManager.connect(supplier1).createMarkets([config.tokens.cEth.address])).to.be.reverted;
      expect(creamPositionsManager.connect(borrower1).createMarkets([config.tokens.cEth.address])).to.be.reverted;
      expect(creamPositionsManager.connect(owner).createMarkets([config.tokens.cEth.address])).to.be.reverted;
      await compMarketsManager.connect(owner).createMarkets([config.tokens.cEth.address]);
      expect(await comptroller.checkMembership(creamPositionsManager.address, config.tokens.cEth.address)).to.be.true;
    });

    it('Only Owner should be able to set CreamPositionsManager on Morpho', async () => {
      expect(compMarketsManager.connect(supplier1).setCompPositionsManager(fakeCreamPositionsManager.address)).to.be.reverted;
      expect(compMarketsManager.connect(borrower1).setCompPositionsManager(fakeCreamPositionsManager.address)).to.be.reverted;
      expect(compMarketsManager.connect(owner).setCompPositionsManager(fakeCreamPositionsManager.address)).not.be.reverted;
      await compMarketsManager.connect(owner).setCompPositionsManager(fakeCreamPositionsManager.address);
      expect(await compMarketsManager.compPositionsManager()).to.equal(fakeCreamPositionsManager.address);
    });

    it('Only Owner should be able to update thresholds', async () => {
      const newThreshold = utils.parseUnits('2');
      await compMarketsManager.connect(owner).updateThreshold(config.tokens.cUsdc.address, newThreshold);

      // Other accounts than Owner
      await expect(compMarketsManager.connect(supplier1).updateThreshold(config.tokens.cUsdc.address, newThreshold)).to.be.reverted;
      await expect(compMarketsManager.connect(borrower1).updateThreshold(config.tokens.cUsdc.address, newThreshold)).to.be.reverted;
    });

    it('Only Owner should be allowed to list/unlisted a market', async () => {
      await compMarketsManager.connect(owner).createMarkets([config.tokens.cEth.address]);
      expect(compMarketsManager.connect(supplier1).listMarket(config.tokens.cEth.address)).to.be.reverted;
      expect(compMarketsManager.connect(borrower1).listMarket(config.tokens.cEth.address)).to.be.reverted;
      expect(compMarketsManager.connect(supplier1).unlistMarket(config.tokens.cEth.address)).to.be.reverted;
      expect(compMarketsManager.connect(borrower1).unlistMarket(config.tokens.cEth.address)).to.be.reverted;
      expect(compMarketsManager.connect(owner).listMarket(config.tokens.cEth.address)).not.to.be.reverted;
      expect(compMarketsManager.connect(owner).unlistMarket(config.tokens.cEth.address)).not.to.be.reverted;
    });

    it('Should create a market the with right values', async () => {
      const supplyBPY = await cMkrToken.supplyRatePerBlock();
      const borrowBPY = await cMkrToken.borrowRatePerBlock();
      const { blockNumber } = await compMarketsManager.connect(owner).createMarkets([config.tokens.cMkr.address]);
      expect(await compMarketsManager.isListed(config.tokens.cMkr.address)).not.to.be.true;

      const p2pBPY = supplyBPY.add(borrowBPY).div(2);
      expect(await compMarketsManager.p2pBPY(config.tokens.cMkr.address)).to.equal(p2pBPY);

      expect(await compMarketsManager.mUnitExchangeRate(config.tokens.cMkr.address)).to.equal(SCALE);
      expect(await compMarketsManager.lastUpdateBlockNumber(config.tokens.cMkr.address)).to.equal(blockNumber);
    });
  });

  describe('Suppliers on Compound (no borrowers)', () => {
    it('Should have correct balances at the beginning', async () => {
      expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp).to.equal(0);
      expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onMorpho).to.equal(0);
    });

    it('Should revert when supply less than the required threshold', async () => {
      await expect(creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, underlyingThreshold.sub(1))).to.be.reverted;
    });

    it('Should have the correct balances after supply', async () => {
      const amount = utils.parseUnits('10');
      const daiBalanceBefore = await daiToken.balanceOf(supplier1.getAddress());
      const expectedDaiBalanceAfter = daiBalanceBefore.sub(amount);
      await daiToken.connect(supplier1).approve(creamPositionsManager.address, amount);
      await creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, amount);
      const daiBalanceAfter = await daiToken.balanceOf(supplier1.getAddress());

      // Check ERC20 balance
      expect(daiBalanceAfter).to.equal(expectedDaiBalanceAfter);
      const exchangeRate = await cDaiToken.callStatic.exchangeRateCurrent();
      const expectedSupplyBalanceOnComp = underlyingToCToken(amount, exchangeRate);
      expect(await cDaiToken.balanceOf(creamPositionsManager.address)).to.equal(expectedSupplyBalanceOnComp);
      expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp).to.equal(expectedSupplyBalanceOnComp);
      expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onMorpho).to.equal(0);
    });

    it('Should be able to redeem ERC20 right after supply up to max supply balance', async () => {
      const amount = utils.parseUnits('10');
      const daiBalanceBefore1 = await daiToken.balanceOf(supplier1.getAddress());
      await daiToken.connect(supplier1).approve(creamPositionsManager.address, amount);
      await creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, amount);
      const daiBalanceAfter1 = await daiToken.balanceOf(supplier1.getAddress());
      expect(daiBalanceAfter1).to.equal(daiBalanceBefore1.sub(amount));

      const supplyBalanceOnComp = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp;
      const exchangeRate1 = await cDaiToken.callStatic.exchangeRateCurrent();
      const toWithdraw1 = cTokenToUnderlying(supplyBalanceOnComp, exchangeRate1);

      // TODO: improve this test to prevent attacks
      await expect(creamPositionsManager.connect(supplier1).redeem(toWithdraw1.add(utils.parseUnits('0.001')).toString())).to.be.reverted;

      // Update exchange rate
      await cDaiToken.connect(supplier1).exchangeRateCurrent();
      const exchangeRate2 = await cDaiToken.callStatic.exchangeRateCurrent();
      const toWithdraw2 = cTokenToUnderlying(supplyBalanceOnComp, exchangeRate2);
      await creamPositionsManager.connect(supplier1).redeem(config.tokens.cDai.address, toWithdraw2);
      const daiBalanceAfter2 = await daiToken.balanceOf(supplier1.getAddress());
      // Check ERC20 balance
      expect(daiBalanceAfter2).to.equal(daiBalanceBefore1.sub(amount).add(toWithdraw2));

      // Check cToken left are only dust in supply balance
      expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp).to.be.lt(1000);
      await expect(creamPositionsManager.connect(supplier1).redeem(config.tokens.cDai.address, utils.parseUnits('0.001'))).to.be.reverted;
    });

    it('Should be able to deposit more ERC20 after already having deposit ERC20', async () => {
      const amount = utils.parseUnits('10');
      const amountToApprove = utils.parseUnits('10').mul(2);
      const daiBalanceBefore = await daiToken.balanceOf(supplier1.getAddress());

      await daiToken.connect(supplier1).approve(creamPositionsManager.address, amountToApprove);
      await creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, amount);
      const exchangeRate1 = await cDaiToken.callStatic.exchangeRateCurrent();
      await creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, amount);
      const exchangeRate2 = await cDaiToken.callStatic.exchangeRateCurrent();

      // Check ERC20 balance
      const daiBalanceAfter = await daiToken.balanceOf(supplier1.getAddress());
      expect(daiBalanceAfter).to.equal(daiBalanceBefore.sub(amountToApprove));

      // Check supply balance
      const expectedSupplyBalanceOnComp1 = underlyingToCToken(amount, exchangeRate1);
      const expectedSupplyBalanceOnComp2 = underlyingToCToken(amount, exchangeRate2);
      const expectedSupplyBalanceOnComp = expectedSupplyBalanceOnComp1.add(expectedSupplyBalanceOnComp2);
      expect(await cDaiToken.balanceOf(creamPositionsManager.address)).to.equal(expectedSupplyBalanceOnComp);
      expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp).to.equal(expectedSupplyBalanceOnComp);
    });

    it('Several suppliers should be able to deposit and have the correct balances', async () => {
      const amount = utils.parseUnits('10');
      let expectedCTokenBalance = BigNumber.from(0);

      for (const i in suppliers) {
        const supplier = suppliers[i];
        const daiBalanceBefore = await daiToken.balanceOf(supplier.getAddress());
        const expectedDaiBalanceAfter = daiBalanceBefore.sub(amount);
        await daiToken.connect(supplier).approve(creamPositionsManager.address, amount);
        await creamPositionsManager.connect(supplier).deposit(config.tokens.cDai.address, amount);
        const exchangeRate = await cDaiToken.callStatic.exchangeRateCurrent();
        const daiBalanceAfter = await daiToken.balanceOf(supplier.getAddress());

        // Check ERC20 balance
        expect(daiBalanceAfter).to.equal(expectedDaiBalanceAfter);
        const expectedSupplyBalanceOnComp = underlyingToCToken(amount, exchangeRate);
        expectedCTokenBalance = expectedCTokenBalance.add(expectedSupplyBalanceOnComp);
        expect(removeDigitsBigNumber(7, await cDaiToken.balanceOf(creamPositionsManager.address))).to.equal(removeDigitsBigNumber(7, expectedCTokenBalance));
        expect(removeDigitsBigNumber(4, (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier.getAddress())).onComp)).to.equal(
          removeDigitsBigNumber(4, expectedSupplyBalanceOnComp)
        );
        expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier.getAddress())).onMorpho).to.equal(0);
      }
    });
  });

  describe('Borrowers on Compound (no suppliers)', () => {
    it('Should have correct balances at the beginning', async () => {
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp).to.equal(0);
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho).to.equal(0);
    });

    it('Should revert when providing 0 as collateral', async () => {
      await expect(creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, 0)).to.be.reverted;
    });

    it('Should revert when borrow less than threshold', async () => {
      const amount = to6Decimals(utils.parseUnits('10'));
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, amount);
      await expect(creamPositionsManager.connect(supplier1).borrow(config.tokens.cDai.address, amount)).to.be.reverted;
    });

    it('Should be able to borrow on Compound after providing collateral up to max', async () => {
      const amount = to6Decimals(utils.parseUnits('100'));
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, amount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, amount);
      const cExchangeRate = await cUsdcToken.callStatic.exchangeRateCurrent();
      const collateralBalanceInCToken = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onComp;
      const collateralBalanceInUnderlying = cTokenToUnderlying(collateralBalanceInCToken, cExchangeRate);
      const { collateralFactorMantissa } = await comptroller.markets(config.tokens.cDai.address);
      const usdcPriceMantissa = await compoundOracle.getUnderlyingPrice(config.tokens.cUsdc.address);
      const daiPriceMantissa = await compoundOracle.getUnderlyingPrice(config.tokens.cDai.address);
      const maxToBorrow = collateralBalanceInUnderlying.mul(usdcPriceMantissa).div(daiPriceMantissa).mul(collateralFactorMantissa).div(SCALE);
      const daiBalanceBefore = await daiToken.balanceOf(borrower1.getAddress());

      // Borrow
      await creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, maxToBorrow);
      const borrowIndex = await cDaiToken.borrowIndex();
      const daiBalanceAfter = await daiToken.balanceOf(borrower1.getAddress());

      // Check borrower1 balances
      expect(daiBalanceAfter).to.equal(daiBalanceBefore.add(maxToBorrow));
      const borrowBalanceOnCompInUnderlying = cDUnitToUnderlying((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp, borrowIndex);
      let diff;
      if (borrowBalanceOnCompInUnderlying.gt(maxToBorrow)) diff = borrowBalanceOnCompInUnderlying.sub(maxToBorrow);
      else diff = maxToBorrow.sub(borrowBalanceOnCompInUnderlying);
      expect(removeDigitsBigNumber(1, diff)).to.equal(0);

      // Check Morpho balances
      expect(await daiToken.balanceOf(creamPositionsManager.address)).to.equal(0);
      expect(await cDaiToken.callStatic.borrowBalanceCurrent(creamPositionsManager.address)).to.equal(maxToBorrow);
    });

    it('Should not be able to borrow more than max allowed given an amount of collateral', async () => {
      const amount = to6Decimals(utils.parseUnits('100'));
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, amount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, amount);
      const collateralBalanceInCToken = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onComp;
      const cExchangeRate = await cUsdcToken.callStatic.exchangeRateCurrent();
      const collateralBalanceInUnderlying = cTokenToUnderlying(collateralBalanceInCToken, cExchangeRate);
      const { collateralFactorMantissa } = await comptroller.markets(config.tokens.cDai.address);
      const usdcPriceMantissa = await compoundOracle.getUnderlyingPrice(config.tokens.cUsdc.address);
      const daiPriceMantissa = await compoundOracle.getUnderlyingPrice(config.tokens.cDai.address);
      const maxToBorrow = collateralBalanceInUnderlying.mul(usdcPriceMantissa).div(daiPriceMantissa).mul(collateralFactorMantissa).div(SCALE);
      // WARNING: maxToBorrow seems to be not accurate
      const moreThanMaxToBorrow = maxToBorrow.add(utils.parseUnits('10'));

      // TODO: fix dust issue
      // This check does not pass when adding utils.parseUnits("0.00001") to maxToBorrow
      await expect(creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, moreThanMaxToBorrow)).to.be.reverted;
    });

    it('Several borrowers should be able to borrow and have the correct balances', async () => {
      const collateralAmount = to6Decimals(utils.parseUnits('10'));
      const borrowedAmount = utils.parseUnits('2');
      let expectedMorphoBorrowBalance = BigNumber.from(0);
      let previousBorrowIndex = await cDaiToken.borrowIndex();

      for (const i in borrowers) {
        const borrower = borrowers[i];
        await usdcToken.connect(borrower).approve(creamPositionsManager.address, collateralAmount);
        await creamPositionsManager.connect(borrower).deposit(config.tokens.cUsdc.address, collateralAmount);
        const daiBalanceBefore = await daiToken.balanceOf(borrower.getAddress());

        await creamPositionsManager.connect(borrower).borrow(config.tokens.cDai.address, borrowedAmount);
        // We have one block delay from Compound
        const borrowIndex = await cDaiToken.borrowIndex();
        expectedMorphoBorrowBalance = expectedMorphoBorrowBalance.mul(borrowIndex).div(previousBorrowIndex).add(borrowedAmount);

        // All underlyings should have been sent to the borrower
        const daiBalanceAfter = await daiToken.balanceOf(borrower.getAddress());
        expect(daiBalanceAfter).to.equal(daiBalanceBefore.add(borrowedAmount));
        const borrowBalanceOnCompInUnderlying = cDUnitToUnderlying((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower.getAddress())).onComp, borrowIndex);
        let diff;
        if (borrowBalanceOnCompInUnderlying.gt(borrowedAmount)) diff = borrowBalanceOnCompInUnderlying.sub(borrowedAmount);
        else diff = borrowedAmount.sub(borrowBalanceOnCompInUnderlying);
        expect(removeDigitsBigNumber(1, diff)).to.equal(0);
        // Update previous borrow index
        previousBorrowIndex = borrowIndex;
      }

      // Check Morpho balances
      expect(await daiToken.balanceOf(creamPositionsManager.address)).to.equal(0);
      expect(await cDaiToken.callStatic.borrowBalanceCurrent(creamPositionsManager.address)).to.equal(expectedMorphoBorrowBalance);
    });

    it('Borrower should be able to repay less than what is on Compound', async () => {
      const amount = to6Decimals(utils.parseUnits('100'));
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, amount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, amount);
      const collateralBalanceInCToken = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onComp;
      const cExchangeRate = await cUsdcToken.callStatic.exchangeRateCurrent();
      const collateralBalanceInUnderlying = cTokenToUnderlying(collateralBalanceInCToken, cExchangeRate);
      const { collateralFactorMantissa } = await comptroller.markets(config.tokens.cDai.address);
      const usdcPriceMantissa = await compoundOracle.getUnderlyingPrice(config.tokens.cUsdc.address);
      const daiPriceMantissa = await compoundOracle.getUnderlyingPrice(config.tokens.cDai.address);
      const maxToBorrow = collateralBalanceInUnderlying.mul(usdcPriceMantissa).div(daiPriceMantissa).mul(collateralFactorMantissa).div(SCALE);

      const daiBalanceBefore = await daiToken.balanceOf(borrower1.getAddress());
      await creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, maxToBorrow);
      const borrowBalanceOnComp = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp;
      const borrowIndex1 = await cDaiToken.borrowIndex();
      const borrowBalanceOnCompInUnderlying = cDUnitToUnderlying(borrowBalanceOnComp, borrowIndex1);
      const toRepay = borrowBalanceOnCompInUnderlying.div(2);
      await daiToken.connect(borrower1).approve(creamPositionsManager.address, toRepay);
      const borrowIndex2 = await cDaiToken.borrowIndex();
      await creamPositionsManager.connect(borrower1).repay(config.tokens.cDai.address, toRepay);
      const daiBalanceAfter = await daiToken.balanceOf(borrower1.getAddress());

      const expectedBalanceOnComp = borrowBalanceOnComp.sub(underlyingToCdUnit(borrowBalanceOnCompInUnderlying.div(2), borrowIndex2));
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp).to.equal(expectedBalanceOnComp);
      expect(daiBalanceAfter).to.equal(daiBalanceBefore.add(maxToBorrow).sub(toRepay));
    });
  });

  describe('P2P interactions between supplier and borrowers', () => {
    it('Supplier should withdraw her liquidity while not enough cToken on Morpho contract', async () => {
      // Supplier deposits tokens
      const supplyAmount = utils.parseUnits('10');
      const daiBalanceBefore1 = await daiToken.balanceOf(supplier1.getAddress());
      const expectedDaiBalanceAfter1 = daiBalanceBefore1.sub(supplyAmount);
      await daiToken.connect(supplier1).approve(creamPositionsManager.address, supplyAmount);
      await creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, supplyAmount);
      const daiBalanceAfter1 = await daiToken.balanceOf(supplier1.getAddress());

      // Check ERC20 balance
      expect(daiBalanceAfter1).to.equal(expectedDaiBalanceAfter1);
      const cExchangeRate1 = await cDaiToken.callStatic.exchangeRateCurrent();
      const expectedSupplyBalanceOnComp1 = underlyingToCToken(supplyAmount, cExchangeRate1);
      expect(await cDaiToken.balanceOf(creamPositionsManager.address)).to.equal(expectedSupplyBalanceOnComp1);
      expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp).to.equal(expectedSupplyBalanceOnComp1);

      // Borrower provides collateral
      const collateralAmount = to6Decimals(utils.parseUnits('100'));
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, collateralAmount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, collateralAmount);

      // Borrowers borrows supplier1 amount
      await creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, supplyAmount);

      // Check supplier1 balances
      const cExchangeRate2 = await cDaiToken.callStatic.exchangeRateCurrent();
      const mExchangeRate1 = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);
      const expectedSupplyBalanceOnComp2 = expectedSupplyBalanceOnComp1.sub(underlyingToCToken(supplyAmount, cExchangeRate2));
      const expectedSupplyBalanceOnMorpho2 = underlyingToMUnit(supplyAmount, mExchangeRate1);
      const supplyBalanceOnComp2 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp;
      const supplyBalanceOnMorpho2 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onMorpho;
      expect(supplyBalanceOnComp2).to.equal(expectedSupplyBalanceOnComp2);
      expect(supplyBalanceOnMorpho2).to.equal(expectedSupplyBalanceOnMorpho2);

      // Check borrower1 balances
      const expectedBorrowBalanceOnMorpho1 = expectedSupplyBalanceOnMorpho2;
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp).to.equal(0);
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho).to.equal(expectedBorrowBalanceOnMorpho1);

      // Compare remaining to withdraw and the cToken contract balance
      await compMarketsManager.connect(owner).updateMUnitExchangeRate(config.tokens.cDai.address);
      const mExchangeRate2 = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);
      const mExchangeRate3 = computeNewMorphoExchangeRate(mExchangeRate2, await compMarketsManager.p2pBPY(config.tokens.cDai.address), 1, 0).toString();
      const daiBalanceBefore2 = await daiToken.balanceOf(supplier1.getAddress());
      const supplyBalanceOnComp3 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp;
      const supplyBalanceOnMorpho3 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onMorpho;
      const cExchangeRate3 = await cDaiToken.callStatic.exchangeRateStored();
      const supplyBalanceOnCompInUnderlying = cTokenToUnderlying(supplyBalanceOnComp3, cExchangeRate3);
      const amountToWithdraw = supplyBalanceOnCompInUnderlying.add(mUnitToUnderlying(supplyBalanceOnMorpho3, mExchangeRate3));
      const expectedDaiBalanceAfter2 = daiBalanceBefore2.add(amountToWithdraw);
      const remainingToWithdraw = amountToWithdraw.sub(supplyBalanceOnCompInUnderlying);
      const cTokenContractBalanceInUnderlying = cTokenToUnderlying(await cDaiToken.balanceOf(creamPositionsManager.address), cExchangeRate3);
      expect(remainingToWithdraw).to.be.gt(cTokenContractBalanceInUnderlying);

      // Expected borrow balances
      const expectedMorphoBorrowBalance = remainingToWithdraw.add(cTokenContractBalanceInUnderlying).sub(supplyBalanceOnCompInUnderlying);

      // Withdraw
      await creamPositionsManager.connect(supplier1).redeem(config.tokens.cDai.address, amountToWithdraw);
      const borrowIndex = await cDaiToken.borrowIndex();
      const expectedBorrowerBorrowBalanceOnComp = underlyingToCdUnit(expectedMorphoBorrowBalance, borrowIndex);
      const borrowBalance = await cDaiToken.callStatic.borrowBalanceCurrent(creamPositionsManager.address);
      const daiBalanceAfter2 = await daiToken.balanceOf(supplier1.getAddress());

      // Check borrow balance of Morpho
      expect(removeDigitsBigNumber(10, borrowBalance)).to.equal(removeDigitsBigNumber(10, expectedMorphoBorrowBalance));

      // Check supplier1 underlying balance
      expect(removeDigitsBigNumber(1, daiBalanceAfter2)).to.equal(removeDigitsBigNumber(1, expectedDaiBalanceAfter2));

      // Check supply balances of supplier1
      expect(removeDigitsBigNumber(1, (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp)).to.equal(0);
      expect(removeDigitsBigNumber(9, (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onMorpho)).to.equal(0);

      // Check borrow balances of borrower1
      expect(removeDigitsBigNumber(9, (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp)).to.equal(
        removeDigitsBigNumber(9, expectedBorrowerBorrowBalanceOnComp)
      );
      expect(removeDigitsBigNumber(9, (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho)).to.equal(0);
    });

    it('Supplier should redeem her liquidity while enough cDaiToken on Morpho contract', async () => {
      const supplyAmount = utils.parseUnits('10');
      let supplier;

      for (const i in suppliers) {
        supplier = suppliers[i];
        const daiBalanceBefore = await daiToken.balanceOf(supplier.getAddress());
        const expectedDaiBalanceAfter = daiBalanceBefore.sub(supplyAmount);
        await daiToken.connect(supplier).approve(creamPositionsManager.address, supplyAmount);
        await creamPositionsManager.connect(supplier).deposit(config.tokens.cDai.address, supplyAmount);
        const daiBalanceAfter = await daiToken.balanceOf(supplier.getAddress());

        // Check ERC20 balance
        expect(daiBalanceAfter).to.equal(expectedDaiBalanceAfter);
        const cExchangeRate = await cDaiToken.callStatic.exchangeRateStored();
        const expectedSupplyBalanceOnComp = underlyingToCToken(supplyAmount, cExchangeRate);
        expect(removeDigitsBigNumber(4, (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier.getAddress())).onComp)).to.equal(
          removeDigitsBigNumber(4, expectedSupplyBalanceOnComp)
        );
      }

      // Borrower provides collateral
      const collateralAmount = to6Decimals(utils.parseUnits('100'));
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, collateralAmount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, collateralAmount);

      const previousSupplier1SupplyBalanceOnComp = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp;

      // Borrowers borrows supplier1 amount
      await creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, supplyAmount);

      // Check supplier1 balances
      const mExchangeRate1 = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);
      const cExchangeRate2 = await cDaiToken.callStatic.exchangeRateCurrent();
      // Expected balances of supplier1
      const expectedSupplyBalanceOnComp2 = previousSupplier1SupplyBalanceOnComp.sub(underlyingToCToken(supplyAmount, cExchangeRate2));
      const expectedSupplyBalanceOnMorpho2 = underlyingToMUnit(supplyAmount, mExchangeRate1);
      const supplyBalanceOnComp2 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp;
      const supplyBalanceOnMorpho2 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onMorpho;
      expect(supplyBalanceOnComp2).to.equal(expectedSupplyBalanceOnComp2);
      expect(supplyBalanceOnMorpho2).to.equal(expectedSupplyBalanceOnMorpho2);

      // Check borrower1 balances
      const expectedBorrowBalanceOnMorpho1 = expectedSupplyBalanceOnMorpho2;
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp).to.equal(0);
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho).to.equal(expectedBorrowBalanceOnMorpho1);

      // Compare remaining to withdraw and the cToken contract balance
      await compMarketsManager.connect(owner).updateMUnitExchangeRate(config.tokens.cDai.address);
      const mExchangeRate2 = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);
      const mExchangeRate3 = computeNewMorphoExchangeRate(mExchangeRate2, await compMarketsManager.p2pBPY(config.tokens.cDai.address), 1, 0).toString();
      const daiBalanceBefore2 = await daiToken.balanceOf(supplier1.getAddress());
      const supplyBalanceOnComp3 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp;
      const supplyBalanceOnMorpho3 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onMorpho;
      const cExchangeRate3 = await cDaiToken.callStatic.exchangeRateCurrent();
      const supplyBalanceOnCompInUnderlying = cTokenToUnderlying(supplyBalanceOnComp3, cExchangeRate3);
      const amountToWithdraw = supplyBalanceOnCompInUnderlying.add(mUnitToUnderlying(supplyBalanceOnMorpho3, mExchangeRate3));
      const expectedDaiBalanceAfter2 = daiBalanceBefore2.add(amountToWithdraw);
      const remainingToWithdraw = amountToWithdraw.sub(supplyBalanceOnCompInUnderlying);
      const cTokenContractBalanceInUnderlying = cTokenToUnderlying(await cDaiToken.balanceOf(creamPositionsManager.address), cExchangeRate3);
      expect(remainingToWithdraw).to.be.lt(cTokenContractBalanceInUnderlying);

      // supplier3 balances before the withdraw
      const supplier3SupplyBalanceOnComp = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier3.getAddress())).onComp;
      const supplier3SupplyBalanceOnMorpho = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier3.getAddress())).onMorpho;

      // supplier2 balances before the withdraw
      const supplier2SupplyBalanceOnComp = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier2.getAddress())).onComp;
      const supplier2SupplyBalanceOnMorpho = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier2.getAddress())).onMorpho;

      // borrower1 balances before the withdraw
      const borrower1BorrowBalanceOnComp = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp;
      const borrower1BorrowBalanceOnMorpho = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho;

      // Withdraw
      await creamPositionsManager.connect(supplier1).redeem(config.tokens.cDai.address, amountToWithdraw);
      const cExchangeRate4 = await cDaiToken.callStatic.exchangeRateStored();
      const borrowBalance = await cDaiToken.callStatic.borrowBalanceCurrent(creamPositionsManager.address);
      const daiBalanceAfter2 = await daiToken.balanceOf(supplier1.getAddress());

      const supplier2SupplyBalanceOnCompInUnderlying = cTokenToUnderlying(supplier2SupplyBalanceOnComp, cExchangeRate4);
      const amountToMove = bigNumberMin(supplier2SupplyBalanceOnCompInUnderlying, remainingToWithdraw);
      const mExchangeRate4 = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);
      const expectedSupplier2SupplyBalanceOnComp = supplier2SupplyBalanceOnComp.sub(underlyingToCToken(amountToMove, cExchangeRate4));
      const expectedSupplier2SupplyBalanceOnMorpho = supplier2SupplyBalanceOnMorpho.add(underlyingToMUnit(amountToMove, mExchangeRate4));

      // Check borrow balance of Morpho
      expect(borrowBalance).to.equal(0);

      // Check supplier1 underlying balance
      expect(daiBalanceAfter2).to.equal(expectedDaiBalanceAfter2);

      // Check supply balances of supplier1
      expect(removeDigitsBigNumber(1, (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp)).to.equal(0);
      expect(removeDigitsBigNumber(5, (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onMorpho)).to.equal(0);

      // Check supply balances of supplier2: supplier2 should have replaced supplier1
      expect(removeDigitsBigNumber(1, (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier2.getAddress())).onComp)).to.equal(
        removeDigitsBigNumber(1, expectedSupplier2SupplyBalanceOnComp)
      );
      expect(removeDigitsBigNumber(7, (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier2.getAddress())).onMorpho)).to.equal(
        removeDigitsBigNumber(7, expectedSupplier2SupplyBalanceOnMorpho)
      );

      // Check supply balances of supplier3: supplier3 balances should not move
      expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier3.getAddress())).onComp).to.equal(supplier3SupplyBalanceOnComp);
      expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier3.getAddress())).onMorpho).to.equal(supplier3SupplyBalanceOnMorpho);

      // Check borrow balances of borrower1: borrower1 balances should not move (except interest earn meanwhile)
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp).to.equal(borrower1BorrowBalanceOnComp);
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho).to.equal(borrower1BorrowBalanceOnMorpho);
    });

    it('Borrower on Morpho only, should be able to repay all borrow amount', async () => {
      // Supplier deposits tokens
      const supplyAmount = utils.parseUnits('10');
      await daiToken.connect(supplier1).approve(creamPositionsManager.address, supplyAmount);
      await creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, supplyAmount);

      // Borrower borrows half of the tokens
      const collateralAmount = to6Decimals(utils.parseUnits('100'));
      const daiBalanceBefore = await daiToken.balanceOf(borrower1.getAddress());
      const toBorrow = supplyAmount.div(2);

      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, collateralAmount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, collateralAmount);
      await creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, toBorrow);

      const borrowerBalanceOnMorpho = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho;
      const p2pBPY = await compMarketsManager.p2pBPY(config.tokens.cDai.address);
      await compMarketsManager.updateMUnitExchangeRate(config.tokens.cDai.address);
      const mUnitExchangeRate = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);
      // WARNING: Should be one block but the pow function used in contract is not accurate
      const mExchangeRate = computeNewMorphoExchangeRate(mUnitExchangeRate, p2pBPY, 1, 0).toString();
      const toRepay = mUnitToUnderlying(borrowerBalanceOnMorpho, mExchangeRate);
      const expectedDaiBalanceAfter = daiBalanceBefore.add(toBorrow).sub(toRepay);
      const previousMorphoCTokenBalance = await cDaiToken.balanceOf(creamPositionsManager.address);

      // Repay
      await daiToken.connect(borrower1).approve(creamPositionsManager.address, toRepay);
      await creamPositionsManager.connect(borrower1).repay(config.tokens.cDai.address, toRepay);
      const cExchangeRate = await cDaiToken.callStatic.exchangeRateStored();
      const expectedMorphoCTokenBalance = previousMorphoCTokenBalance.add(underlyingToCToken(toRepay, cExchangeRate));

      // Check borrower1 balances
      const daiBalanceAfter = await daiToken.balanceOf(borrower1.getAddress());
      expect(daiBalanceAfter).to.equal(expectedDaiBalanceAfter);
      // TODO: implement interest for borrowers to complete this test as borrower's debt is not increasing here
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp).to.equal(0);
      // Commented here due to the pow function issue
      // expect(removeDigitsBigNumber(1, (await creamPositionsManager.borrowBalanceInOf(borrower1.getAddress())).onMorpho)).to.equal(0);

      // Check Morpho balances
      expect(await cDaiToken.balanceOf(creamPositionsManager.address)).to.equal(expectedMorphoCTokenBalance);
      expect(await cDaiToken.callStatic.borrowBalanceCurrent(creamPositionsManager.address)).to.equal(0);
    });

    it('Borrower on Morpho and on Compound, should be able to repay all borrow amount', async () => {
      // Supplier deposits tokens
      const supplyAmount = utils.parseUnits('10');
      const amountToApprove = utils.parseUnits('100000000');
      await daiToken.connect(supplier1).approve(creamPositionsManager.address, supplyAmount);
      await creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, supplyAmount);

      // Borrower borrows two times the amount of tokens;
      const collateralAmount = to6Decimals(utils.parseUnits('100'));
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, collateralAmount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, collateralAmount);
      const daiBalanceBefore = await daiToken.balanceOf(borrower1.getAddress());
      const toBorrow = supplyAmount.mul(2);
      const supplyBalanceOnComp = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp;
      await creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, toBorrow);

      const cExchangeRate1 = await cDaiToken.callStatic.exchangeRateStored();
      const expectedMorphoBorrowBalance1 = toBorrow.sub(cTokenToUnderlying(supplyBalanceOnComp, cExchangeRate1));
      const morphoBorrowBalanceBefore1 = await cDaiToken.callStatic.borrowBalanceCurrent(creamPositionsManager.address);
      expect(removeDigitsBigNumber(6, morphoBorrowBalanceBefore1)).to.equal(removeDigitsBigNumber(6, expectedMorphoBorrowBalance1));
      await daiToken.connect(borrower1).approve(creamPositionsManager.address, amountToApprove);

      const borrowerBalanceOnMorpho = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho;
      const p2pBPY = await compMarketsManager.p2pBPY(config.tokens.cDai.address);
      const mUnitExchangeRate = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);
      // WARNING: Should be 2 blocks but the pow function used in contract is not accurate
      const mExchangeRate = computeNewMorphoExchangeRate(mUnitExchangeRate, p2pBPY, 1, 0).toString();
      const borrowerBalanceOnMorphoInUnderlying = mUnitToUnderlying(borrowerBalanceOnMorpho, mExchangeRate);

      // Compute how much to repay
      const doUpdate = await cDaiToken.borrowBalanceCurrent(creamPositionsManager.address);
      await doUpdate.wait(1);
      const borrowIndex1 = await cDaiToken.borrowIndex();
      const borrowerBalanceOnComp = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp;
      const toRepay = borrowerBalanceOnComp.mul(borrowIndex1).div(SCALE).add(borrowerBalanceOnMorphoInUnderlying);
      const expectedDaiBalanceAfter = daiBalanceBefore.add(toBorrow).sub(toRepay);
      const previousMorphoCTokenBalance = await cDaiToken.balanceOf(creamPositionsManager.address);

      // Repay
      await daiToken.connect(borrower1).approve(creamPositionsManager.address, toRepay);
      const borrowIndex3 = await cDaiToken.callStatic.borrowIndex();
      await creamPositionsManager.connect(borrower1).repay(config.tokens.cDai.address, toRepay);
      const cExchangeRate2 = await cDaiToken.callStatic.exchangeRateStored();
      const expectedMorphoCTokenBalance = previousMorphoCTokenBalance.add(underlyingToCToken(borrowerBalanceOnMorphoInUnderlying, cExchangeRate2));
      const expectedBalanceOnComp = borrowerBalanceOnComp.sub(borrowerBalanceOnComp.mul(borrowIndex1).div(borrowIndex3));

      // Check borrower1 balances
      const daiBalanceAfter = await daiToken.balanceOf(borrower1.getAddress());
      expect(daiBalanceAfter).to.equal(expectedDaiBalanceAfter);
      const borrower1BorrowBalanceOnComp = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp;
      expect(removeDigitsBigNumber(2, borrower1BorrowBalanceOnComp)).to.equal(removeDigitsBigNumber(2, expectedBalanceOnComp));
      // WARNING: Commented here due to the pow function issue
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho).to.be.lt(1000000000000);

      // Check Morpho balances
      expect(removeDigitsBigNumber(5, await cDaiToken.balanceOf(creamPositionsManager.address))).to.equal(removeDigitsBigNumber(5, expectedMorphoCTokenBalance));
      // Issue here: we cannot access the most updated borrow balance as it's updated during the repayBorrow on Compound.
      // const expectedMorphoBorrowBalance2 = morphoBorrowBalanceBefore2.sub(borrowerBalanceOnComp.mul(borrowIndex2).div(SCALE));
      // expect(removeDigitsBigNumber(3, await cToken.callStatic.borrowBalanceStored(creamPositionsManager.address))).to.equal(removeDigitsBigNumber(3, expectedMorphoBorrowBalance2));
    });

    it('Should disconnect supplier from Morpho when borrow an asset that nobody has on compMarketsManager and the supply balance is partly used', async () => {
      // supplier1 deposits DAI
      const supplyAmount = utils.parseUnits('100');
      await daiToken.connect(supplier1).approve(creamPositionsManager.address, supplyAmount);
      await creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, supplyAmount);

      // borrower1 deposits USDC as collateral
      const collateralAmount = to6Decimals(utils.parseUnits('100'));
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, collateralAmount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, collateralAmount);

      // borrower1 borrows part of the supply amount of supplier1
      const amountToBorrow = supplyAmount.div(2);
      await creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, amountToBorrow);
      const borrowBalanceOnMorpho = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho;

      // supplier1 borrows USDT that nobody is supply on Morpho
      const cDaiExchangeRate1 = await cDaiToken.callStatic.exchangeRateCurrent();
      const mDaiExchangeRate1 = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);
      const supplyBalanceOnComp1 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp;
      const supplyBalanceOnMorpho1 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onMorpho;
      const supplyBalanceOnCompInUnderlying = cTokenToUnderlying(supplyBalanceOnComp1, cDaiExchangeRate1);
      const supplyBalanceMorphoInUnderlying = mUnitToUnderlying(supplyBalanceOnMorpho1, mDaiExchangeRate1);
      const supplyBalanceInUnderlying = supplyBalanceOnCompInUnderlying.add(supplyBalanceMorphoInUnderlying);
      const { collateralFactorMantissa } = await comptroller.markets(config.tokens.cDai.address);
      const usdtPriceMantissa = await compoundOracle.callStatic.getUnderlyingPrice(config.tokens.cUsdt.address);
      const daiPriceMantissa = await compoundOracle.callStatic.getUnderlyingPrice(config.tokens.cDai.address);
      const maxToBorrow = supplyBalanceInUnderlying.mul(daiPriceMantissa).div(usdtPriceMantissa).mul(collateralFactorMantissa).div(SCALE);
      await creamPositionsManager.connect(supplier1).borrow(config.tokens.cUsdt.address, maxToBorrow);

      // Check balances
      const supplyBalanceOnComp2 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp;
      const borrowBalanceOnComp = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp;
      const cDaiExchangeRate2 = await cDaiToken.callStatic.exchangeRateCurrent();
      const cDaiBorrowIndex = await cDaiToken.borrowIndex();
      const mDaiExchangeRate2 = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);
      const expectedBorrowBalanceOnComp = mUnitToUnderlying(borrowBalanceOnMorpho, mDaiExchangeRate2).mul(SCALE).div(cDaiBorrowIndex);
      const usdtBorrowBalance = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cUsdt.address, supplier1.getAddress())).onComp;
      const cUsdtBorrowIndex = await cUsdtToken.borrowIndex();
      const usdtBorrowBalanceInUnderlying = usdtBorrowBalance.mul(cUsdtBorrowIndex).div(SCALE);
      expect(removeDigitsBigNumber(6, supplyBalanceOnComp2)).to.equal(removeDigitsBigNumber(6, underlyingToCToken(supplyBalanceInUnderlying, cDaiExchangeRate2)));
      expect(removeDigitsBigNumber(2, borrowBalanceOnComp)).to.equal(removeDigitsBigNumber(2, expectedBorrowBalanceOnComp));
      expect(removeDigitsBigNumber(2, usdtBorrowBalanceInUnderlying)).to.equal(removeDigitsBigNumber(2, maxToBorrow));
    });

    it('Supplier should be connected to borrowers already on Morpho when depositing', async () => {
      const collateralAmount = to6Decimals(utils.parseUnits('100'));
      const supplyAmount = utils.parseUnits('100');
      const borrowAmount = utils.parseUnits('30');

      // borrower1 borrows
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, collateralAmount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, collateralAmount);
      await creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, borrowAmount);
      const borrower1BorrowBalanceOnComp = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp;

      // borrower2 borrows
      await usdcToken.connect(borrower2).approve(creamPositionsManager.address, collateralAmount);
      await creamPositionsManager.connect(borrower2).deposit(config.tokens.cUsdc.address, collateralAmount);
      await creamPositionsManager.connect(borrower2).borrow(config.tokens.cDai.address, borrowAmount);
      const borrower2BorrowBalanceOnComp = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower2.getAddress())).onComp;

      // borrower3 borrows
      await usdcToken.connect(borrower3).approve(creamPositionsManager.address, collateralAmount);
      await creamPositionsManager.connect(borrower3).deposit(config.tokens.cUsdc.address, collateralAmount);
      await creamPositionsManager.connect(borrower3).borrow(config.tokens.cDai.address, borrowAmount);
      const borrower3BorrowBalanceOnComp = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower3.getAddress())).onComp;

      // supplier1 deposit
      await daiToken.connect(supplier1).approve(creamPositionsManager.address, supplyAmount);
      await creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, supplyAmount);
      const cExchangeRate = await cDaiToken.callStatic.exchangeRateStored();
      const borrowIndex = await cDaiToken.borrowIndex();
      const mUnitExchangeRate = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);

      // Check balances
      const supplyBalanceOnMorpho = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onMorpho;
      const supplyBalanceOnComp = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cDai.address, supplier1.getAddress())).onComp;
      const underlyingMatched = cDUnitToUnderlying(borrower1BorrowBalanceOnComp.add(borrower2BorrowBalanceOnComp).add(borrower3BorrowBalanceOnComp), borrowIndex);
      expectedSupplyBalanceOnMorpho = underlyingMatched.mul(SCALE).div(mUnitExchangeRate);
      expectedSupplyBalanceOnComp = underlyingToCToken(supplyAmount.sub(underlyingMatched), cExchangeRate);
      expect(removeDigitsBigNumber(2, supplyBalanceOnMorpho)).to.equal(removeDigitsBigNumber(2, expectedSupplyBalanceOnMorpho));
      expect(supplyBalanceOnComp).to.equal(expectedSupplyBalanceOnComp);
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp).to.be.lte(1);
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower2.getAddress())).onComp).to.be.lte(1);
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower3.getAddress())).onComp).to.be.lte(1);
    });
  });

  describe('Test liquidation', () => {
    it('Borrower should be liquidated while supply (collateral) is only on Compound', async () => {
      const amount = to6Decimals(utils.parseUnits('100'));
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, amount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, amount);
      const collateralBalanceInCToken = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onComp;
      const cExchangeRate = await cUsdcToken.callStatic.exchangeRateCurrent();
      const collateralBalanceInUnderlying = cTokenToUnderlying(collateralBalanceInCToken, cExchangeRate);
      const { collateralFactorMantissa } = await comptroller.markets(config.tokens.cDai.address);
      const usdcPriceMantissa = await compoundOracle.getUnderlyingPrice(config.tokens.cUsdc.address);
      const daiPriceMantissa = await compoundOracle.getUnderlyingPrice(config.tokens.cDai.address);
      const maxToBorrow = collateralBalanceInUnderlying.mul(usdcPriceMantissa).div(daiPriceMantissa).mul(collateralFactorMantissa).div(SCALE);

      // Borrow
      await creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, maxToBorrow);
      const collateralBalanceBefore = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onComp;
      const borrowBalanceBefore = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp;

      // Mine block
      await hre.network.provider.send('evm_mine', []);

      // Liquidate
      const toRepay = maxToBorrow.div(2);
      await daiToken.connect(liquidator).approve(creamPositionsManager.address, toRepay);
      const usdcBalanceBefore = await usdcToken.balanceOf(liquidator.getAddress());
      const daiBalanceBefore = await daiToken.balanceOf(liquidator.getAddress());
      await creamPositionsManager.connect(liquidator).liquidate(config.tokens.cDai.address, config.tokens.cUsdc.address, borrower1.getAddress(), toRepay);
      const usdcBalanceAfter = await usdcToken.balanceOf(liquidator.getAddress());
      const daiBalanceAfter = await daiToken.balanceOf(liquidator.getAddress());

      // Liquidation parameters
      const borrowIndex = await cDaiToken.borrowIndex();
      const cUsdcExchangeRate = await cUsdcToken.callStatic.exchangeRateCurrent();
      const liquidationIncentive = await comptroller.liquidationIncentiveMantissa();
      const collateralAssetPrice = await compoundOracle.getUnderlyingPrice(config.tokens.cUsdc.address);
      const borrowedAssetPrice = await compoundOracle.getUnderlyingPrice(config.tokens.cDai.address);
      const amountToSeize = toRepay.mul(borrowedAssetPrice).div(collateralAssetPrice).mul(liquidationIncentive).div(SCALE);
      const expectedCollateralBalanceAfter = collateralBalanceBefore.sub(underlyingToCToken(amountToSeize, cUsdcExchangeRate));
      const expectedBorrowBalanceAfter = borrowBalanceBefore.sub(underlyingToCdUnit(toRepay, borrowIndex));
      const expectedUsdcBalanceAfter = usdcBalanceBefore.add(amountToSeize);
      const expectedDaiBalanceAfter = daiBalanceBefore.sub(toRepay);

      // Check balances
      expect(removeDigitsBigNumber(6, (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onComp)).to.equal(
        removeDigitsBigNumber(6, expectedCollateralBalanceAfter)
      );
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp).to.equal(expectedBorrowBalanceAfter);
      expect(removeDigitsBigNumber(1, usdcBalanceAfter)).to.equal(removeDigitsBigNumber(1, expectedUsdcBalanceAfter));
      expect(daiBalanceAfter).to.equal(expectedDaiBalanceAfter);
    });

    it('Borrower should be liquidated while supply (collateral) is on Compound and on Morpho', async () => {
      await daiToken.connect(supplier1).approve(creamPositionsManager.address, utils.parseUnits('1000'));
      await creamPositionsManager.connect(supplier1).deposit(config.tokens.cDai.address, utils.parseUnits('1000'));

      // borrower1 deposits USDC as supply (collateral)
      const amount = to6Decimals(utils.parseUnits('100'));
      await usdcToken.connect(borrower1).approve(creamPositionsManager.address, amount);
      await creamPositionsManager.connect(borrower1).deposit(config.tokens.cUsdc.address, amount);

      // borrower2 borrows part of supply of borrower1 -> borrower1 has supply on Morpho and on Compound
      const toBorrow = amount;
      await uniToken.connect(borrower2).approve(creamPositionsManager.address, utils.parseUnits('200'));
      await creamPositionsManager.connect(borrower2).deposit(config.tokens.cUni.address, utils.parseUnits('200'));
      await creamPositionsManager.connect(borrower2).borrow(config.tokens.cUsdc.address, toBorrow);

      // borrower1 borrows DAI
      const cUsdcExchangeRate1 = await cUsdcToken.callStatic.exchangeRateCurrent();
      const mUsdcExchangeRate1 = await compMarketsManager.mUnitExchangeRate(config.tokens.cUsdc.address);
      const supplyBalanceOnComp1 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onComp;
      const supplyBalanceOnMorpho1 = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onMorpho;
      const supplyBalanceOnCompInUnderlying = cTokenToUnderlying(supplyBalanceOnComp1, cUsdcExchangeRate1);
      const supplyBalanceMorphoInUnderlying = mUnitToUnderlying(supplyBalanceOnMorpho1, mUsdcExchangeRate1);
      const supplyBalanceInUnderlying = supplyBalanceOnCompInUnderlying.add(supplyBalanceMorphoInUnderlying);
      const { collateralFactorMantissa } = await comptroller.markets(config.tokens.cDai.address);
      const usdcPriceMantissa = await compoundOracle.getUnderlyingPrice(config.tokens.cUsdc.address);
      const daiPriceMantissa = await compoundOracle.getUnderlyingPrice(config.tokens.cDai.address);
      const maxToBorrow = supplyBalanceInUnderlying.mul(usdcPriceMantissa).div(daiPriceMantissa).mul(collateralFactorMantissa).div(SCALE);
      await creamPositionsManager.connect(borrower1).borrow(config.tokens.cDai.address, maxToBorrow);
      const collateralBalanceOnCompBefore = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onComp;
      const collateralBalanceOnMorphoBefore = (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onMorpho;
      const borrowBalanceOnMorphoBefore = (await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho;

      // Mine block
      await hre.network.provider.send('evm_mine', []);

      // liquidator liquidates borrower1's position
      const closeFactor = await comptroller.closeFactorMantissa();
      const toRepay = maxToBorrow.mul(closeFactor).div(SCALE);
      await daiToken.connect(liquidator).approve(creamPositionsManager.address, toRepay);
      const usdcBalanceBefore = await usdcToken.balanceOf(liquidator.getAddress());
      const daiBalanceBefore = await daiToken.balanceOf(liquidator.getAddress());
      await creamPositionsManager.connect(liquidator).liquidate(config.tokens.cDai.address, config.tokens.cUsdc.address, borrower1.getAddress(), toRepay);
      const usdcBalanceAfter = await usdcToken.balanceOf(liquidator.getAddress());
      const daiBalanceAfter = await daiToken.balanceOf(liquidator.getAddress());

      // Liquidation parameters
      const mDaiExchangeRate = await compMarketsManager.mUnitExchangeRate(config.tokens.cDai.address);
      const cUsdcExchangeRate = await cUsdcToken.callStatic.exchangeRateCurrent();
      const liquidationIncentive = await comptroller.liquidationIncentiveMantissa();
      const collateralAssetPrice = await compoundOracle.getUnderlyingPrice(config.tokens.cUsdc.address);
      const borrowedAssetPrice = await compoundOracle.getUnderlyingPrice(config.tokens.cDai.address);
      const amountToSeize = toRepay.mul(borrowedAssetPrice).div(collateralAssetPrice).mul(liquidationIncentive).div(SCALE);
      const expectedCollateralBalanceOnMorphoAfter = collateralBalanceOnMorphoBefore.sub(amountToSeize.sub(cTokenToUnderlying(collateralBalanceOnCompBefore, cUsdcExchangeRate)));
      const expectedBorrowBalanceOnMorphoAfter = borrowBalanceOnMorphoBefore.sub(toRepay.mul(SCALE).div(mDaiExchangeRate));
      const expectedUsdcBalanceAfter = usdcBalanceBefore.add(amountToSeize);
      const expectedDaiBalanceAfter = daiBalanceBefore.sub(toRepay);

      // Check liquidatee balances
      expect((await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onComp).to.equal(0);
      expect(removeDigitsBigNumber(2, (await creamPositionsManager.supplyBalanceInOf(config.tokens.cUsdc.address, borrower1.getAddress())).onMorpho)).to.equal(
        removeDigitsBigNumber(2, expectedCollateralBalanceOnMorphoAfter)
      );
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onComp).to.equal(0);
      expect((await creamPositionsManager.borrowBalanceInOf(config.tokens.cDai.address, borrower1.getAddress())).onMorpho).to.equal(expectedBorrowBalanceOnMorphoAfter);

      // Check liquidator balances
      let diff;
      if (usdcBalanceAfter.gt(expectedUsdcBalanceAfter)) diff = usdcBalanceAfter.sub(expectedUsdcBalanceAfter);
      else diff = expectedUsdcBalanceAfter.sub(usdcBalanceAfter);
      expect(removeDigitsBigNumber(1, diff)).to.equal(0);
      expect(daiBalanceAfter).to.equal(expectedDaiBalanceAfter);
    });
  });

  xdescribe('Test attacks', () => {
    it('Should not be DDOS by a supplier or a group of suppliers', async () => {});

    it('Should not be DDOS by a borrower or a group of borrowers', async () => {});

    it('Should not be subject to flash loan attacks', async () => {});

    it('Should not be subjected to Oracle Manipulation attacks', async () => {});
  });
});
