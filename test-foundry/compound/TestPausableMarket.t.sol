// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.13;

import "./setup/TestSetup.sol";

contract TestPausableMarket is TestSetup {
    using CompoundMath for uint256;

    function testOnlyOwnerShouldTriggerPauseFunction() public {
        hevm.expectRevert("Ownable: caller is not the owner");
        supplier1.setPauseStatus(dai);

        positionsManager.setPauseStatus(dai);
        (bool isPaused, ) = positionsManager.pauseStatus(dai);
        assertTrue(isPaused, "paused is false");
    }

    function testOnlyOwnerShouldTriggerPartialPauseFunction() public {
        hevm.expectRevert("Ownable: caller is not the owner");
        supplier1.setPartialPauseStatus(dai);

        positionsManager.setPartialPauseStatus(dai);
        (, bool isPartialPaused) = positionsManager.pauseStatus(dai);
        assertTrue(isPartialPaused, "partial paused is false");
    }

    function testPauseUnpause() public {
        positionsManager.setPauseStatus(dai);
        (bool isPaused, ) = positionsManager.pauseStatus(dai);
        assertTrue(isPaused, "paused is false");

        positionsManager.setPauseStatus(dai);
        (isPaused, ) = positionsManager.pauseStatus(dai);
        assertFalse(isPaused, "paused is true");
    }

    function testPartialPausePartialUnpause() public {
        positionsManager.setPartialPauseStatus(dai);
        (, bool isPartialPaused) = positionsManager.pauseStatus(dai);
        assertTrue(isPartialPaused, "partial paused is false");

        positionsManager.setPartialPauseStatus(dai);
        (, isPartialPaused) = positionsManager.pauseStatus(dai);
        assertFalse(isPartialPaused, "partial paused is true");
    }

    function testShouldTriggerAllFunctionsWhenNotPausedAndNotPartialPaused() public {
        uint256 amount = 10_000 ether;
        uint256 toBorrow = to6Decimals(amount / 2);

        supplier1.approve(dai, amount);
        supplier1.supply(cDai, amount);

        supplier1.borrow(cUsdc, toBorrow);

        supplier1.approve(usdc, toBorrow);
        supplier1.repay(cUsdc, toBorrow);

        (, toBorrow) = positionsManager.getUserMaxCapacitiesForAsset(address(supplier1), cUsdc);
        hevm.expectRevert(Logic.BorrowOnCompoundFailed.selector);
        supplier1.borrow(cUsdc, toBorrow);

        // Change Oracle.
        SimplePriceOracle customOracle = createAndSetCustomPriceOracle();
        customOracle.setUnderlyingPrice(cDai, (oracle.getUnderlyingPrice(cDai) * 95) / 100);

        uint256 toLiquidate = toBorrow / 2;
        User liquidator = borrower3;
        liquidator.approve(usdc, toLiquidate);
        hevm.expectRevert(Logic.DebtValueNotAboveMax.selector);
        liquidator.liquidate(cUsdc, cDai, address(supplier1), toLiquidate);

        supplier1.withdraw(cDai, 1 ether);

        hevm.expectRevert(PositionsManagerEventsErrors.AmountIsZero.selector);
        positionsManager.claimToTreasury(cDai);
    }

    function testShouldNotTriggerAnyFunctionWhenPaused() public {
        uint256 amount = 10_000 ether;

        supplier1.approve(dai, 2 * amount);
        supplier1.supply(cDai, amount);

        (, uint256 toBorrow) = positionsManager.getUserMaxCapacitiesForAsset(
            address(supplier1),
            cUsdc
        );
        supplier1.borrow(cUsdc, toBorrow);

        positionsManager.setPauseStatus(cDai);
        positionsManager.setPauseStatus(cUsdc);

        hevm.expectRevert(abi.encodeWithSignature("MarketPaused()"));
        supplier1.supply(cDai, amount);

        hevm.expectRevert(abi.encodeWithSignature("MarketPaused()"));
        supplier1.borrow(cUsdc, 1);

        supplier1.approve(usdc, toBorrow);
        hevm.expectRevert(abi.encodeWithSignature("MarketPaused()"));
        supplier1.repay(cUsdc, toBorrow);
        hevm.expectRevert(abi.encodeWithSignature("MarketPaused()"));
        supplier1.withdraw(cDai, 1);

        // Change Oracle
        SimplePriceOracle customOracle = createAndSetCustomPriceOracle();
        customOracle.setUnderlyingPrice(cDai, (oracle.getUnderlyingPrice(cDai) * 95) / 100);

        uint256 toLiquidate = toBorrow / 3; // Minus 2 only due to roundings.
        User liquidator = borrower3;
        liquidator.approve(usdc, toLiquidate);

        hevm.expectRevert(abi.encodeWithSignature("MarketPaused()"));
        liquidator.liquidate(cUsdc, cDai, address(supplier1), toLiquidate);

        hevm.expectRevert(abi.encodeWithSignature("MarketPaused()"));
        positionsManager.claimToTreasury(cDai);
    }

    function testShouldOnlyTriggerSpecificFunctionsWhenPartialPaused() public {
        // Specific functions are repay, withdraw and liquidate.
        uint256 amount = 10_000 ether;

        supplier1.approve(dai, 2 * amount);
        supplier1.supply(cDai, amount);

        (, uint256 toBorrow) = positionsManager.getUserMaxCapacitiesForAsset(
            address(supplier1),
            cUsdc
        );
        supplier1.borrow(cUsdc, toBorrow);

        positionsManager.setPartialPauseStatus(cDai);
        positionsManager.setPartialPauseStatus(cUsdc);

        hevm.expectRevert(abi.encodeWithSignature("MarketPaused()"));
        supplier1.supply(cDai, amount);

        hevm.expectRevert(abi.encodeWithSignature("MarketPaused()"));
        supplier1.borrow(cUsdc, 1);

        supplier1.approve(usdc, toBorrow);
        supplier1.repay(cUsdc, 1e6);
        supplier1.withdraw(cDai, 1 ether);

        // Change Oracle
        SimplePriceOracle customOracle = createAndSetCustomPriceOracle();
        customOracle.setUnderlyingPrice(cDai, (oracle.getUnderlyingPrice(cDai) * 97) / 100);

        uint256 toLiquidate = toBorrow / 3;
        User liquidator = borrower3;
        liquidator.approve(usdc, toLiquidate);
        liquidator.liquidate(cUsdc, cDai, address(supplier1), toLiquidate);

        // Does not revert because the market is paused.
        hevm.expectRevert(abi.encodeWithSignature("AmountIsZero()"));
        positionsManager.claimToTreasury(cDai);
    }
}
