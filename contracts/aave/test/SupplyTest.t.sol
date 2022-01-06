// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.7;

import "./TestSetup.sol";

contract SupplyTest is TestSetup {
    // 1.1 - The user supplies less than the threshold of this market, the transaction reverts.
    function testFail_Supply_1_1() public {
        supplier1.approve(dai, positionsManager.threshold(aDai) - 1);
        supplier1.supply(aDai, positionsManager.threshold(aDai) - 1);
    }

    // 1.2 - There are no available borrowers: all of the supplied amount is supplied to the pool and set `onPool`.
    function testSupply_1_2() public {
<<<<<<< HEAD
        uint256 amount = 10000 ether;
=======
        uint256 amount = 100 ether;
>>>>>>> 1e464c8 (feat: Refactor for NMAX and change setup)

        supplier1.approve(dai, amount);
        supplier1.supply(aDai, amount);

        marketsManager.updateRates(aDai);
        uint256 normalizedIncome = lendingPool.getReserveNormalizedIncome(dai);
        uint256 expectedOnPool = underlyingToScaledBalance(amount, normalizedIncome);

        testEquality(IERC20(aDai).balanceOf(address(positionsManager)), amount);

        (uint256 inP2P, uint256 onPool) = positionsManager.supplyBalanceInOf(
            aDai,
            address(supplier1)
        );

        testEquality(onPool, expectedOnPool);
        testEquality(inP2P, 0);
    }

    // Should be able to supply more ERC20 after already having supply ERC20
    function testSupplyMultiple() public {
        uint256 amount = 10000 ether;

        supplier1.approve(dai, 2 * amount);

        supplier1.supply(aDai, amount);
        supplier1.supply(aDai, amount);

        marketsManager.updateRates(aDai);
        uint256 normalizedIncome = lendingPool.getReserveNormalizedIncome(dai);
        uint256 expectedOnPool = underlyingToScaledBalance(2 * amount, normalizedIncome);

        (, uint256 onPool) = positionsManager.supplyBalanceInOf(aDai, address(supplier1));
<<<<<<< HEAD
        testEquality(onPool, expectedOnPool);
=======
        assertLe(get_abs_diff(onPool, expectedOnPool), 1, "Supplier1 on pool");
>>>>>>> 1e464c8 (feat: Refactor for NMAX and change setup)
    }

    // 1.3 - There is 1 available borrower, he matches 100% of the supplier liquidity, everything is `inP2P`.
    function testSupply_1_3() public {
<<<<<<< HEAD
        uint256 amount = 10000 ether;
=======
        uint256 amount = 100 ether;
>>>>>>> 1e464c8 (feat: Refactor for NMAX and change setup)

        borrower1.approve(usdc, to6Decimals(2 * amount));
        borrower1.supply(aUsdc, to6Decimals(2 * amount));
        borrower1.borrow(aDai, amount);

        uint256 daiBalanceBefore = supplier1.balanceOf(dai);
        uint256 expectedDaiBalanceAfter = daiBalanceBefore - amount;

        supplier1.approve(dai, address(positionsManager), amount);
        supplier1.supply(aDai, amount);

        uint256 daiBalanceAfter = supplier1.balanceOf(dai);
        testEquality(daiBalanceAfter, expectedDaiBalanceAfter);

        marketsManager.updateRates(aDai);
        uint256 p2pUnitExchangeRate = marketsManager.p2pExchangeRate(aDai);
        uint256 expectedSupplyBalanceInP2P = underlyingToP2PUnit(amount, p2pUnitExchangeRate);

        (uint256 inP2PSupplier, uint256 onPoolSupplier) = positionsManager.supplyBalanceInOf(
            aDai,
            address(supplier1)
        );

        (uint256 inP2PBorrower, uint256 onPoolBorrower) = positionsManager.borrowBalanceInOf(
            aDai,
            address(borrower1)
        );

        testEquality(onPoolSupplier, 0);
        testEquality(inP2PSupplier, expectedSupplyBalanceInP2P);

        testEquality(onPoolBorrower, 0);
        testEquality(inP2PBorrower, inP2PSupplier);
    }

    // 1.4 - There is 1 available borrower, he doesn't match 100% of the supplier liquidity.
    // Supplier's balance `inP2P` is equal to the borrower previous amount `onPool`, the rest is set `onPool`.
    function testSupply_1_4() public {
<<<<<<< HEAD
        uint256 amount = 10000 ether;
=======
        uint256 amount = 100 ether;
>>>>>>> 1e464c8 (feat: Refactor for NMAX and change setup)

        borrower1.approve(usdc, to6Decimals(2 * amount));
        borrower1.supply(aUsdc, to6Decimals(2 * amount));
        borrower1.borrow(aDai, amount);

        supplier1.approve(dai, 2 * amount);
        supplier1.supply(aDai, 2 * amount);

        marketsManager.updateRates(aDai);
        uint256 p2pUnitExchangeRate = marketsManager.p2pExchangeRate(aDai);
        uint256 expectedSupplyBalanceInP2P = underlyingToP2PUnit(amount, p2pUnitExchangeRate);

        uint256 normalizedIncome = lendingPool.getReserveNormalizedIncome(dai);
        uint256 expectedSupplyBalanceOnPool = underlyingToScaledBalance(amount, normalizedIncome);

        (uint256 inP2PSupplier, uint256 onPoolSupplier) = positionsManager.supplyBalanceInOf(
            aDai,
            address(supplier1)
        );
        testEquality(onPoolSupplier, expectedSupplyBalanceOnPool);
        testEquality(inP2PSupplier, expectedSupplyBalanceInP2P);

        (uint256 inP2PBorrower, uint256 onPoolBorrower) = positionsManager.borrowBalanceInOf(
            aDai,
            address(borrower1)
        );
        testEquality(onPoolBorrower, 0);
        testEquality(inP2PBorrower, inP2PSupplier);
    }

    // 1.5 - There are NMAX (or less) borrowers that match the supplied amount, everything is `inP2P` after NMAX (or less) match.
    function testSupply_1_5() public {
<<<<<<< HEAD
        uint256 amount = 10000 ether;
        uint256 collateral = 2 * amount;

        setNMAXAndCreateSigners(20);
=======
        uint256 amount = 100 ether;
        uint256 collateral = 2 * amount;

        marketsManager.setMaxNumberOfUsersInTree(3);
>>>>>>> 1e464c8 (feat: Refactor for NMAX and change setup)
        uint256 NMAX = positionsManager.NMAX();

        uint256 amountPerBorrower = amount / NMAX;

        for (uint256 i = 0; i < NMAX; i++) {
            borrowers[i].approve(usdc, to6Decimals(collateral));
            borrowers[i].supply(aUsdc, to6Decimals(collateral));

            borrowers[i].borrow(aDai, amountPerBorrower);
        }

        supplier1.approve(dai, amount);
        supplier1.supply(aDai, amount);

        uint256 inP2P;
        uint256 onPool;
        uint256 expectedInP2P;
        uint256 p2pExchangeRate = marketsManager.p2pExchangeRate(aDai);

        for (uint256 i = 0; i < NMAX; i++) {
            (inP2P, onPool) = positionsManager.borrowBalanceInOf(aDai, address(borrowers[i]));

            expectedInP2P = p2pUnitToUnderlying(inP2P, p2pExchangeRate);

<<<<<<< HEAD
            testEquality(expectedInP2P, amountPerBorrower);
            testEquality(onPool, 0);
=======
            assertEq(expectedInP2P, amountPerBorrower);
            assertEq(onPool, 0);
>>>>>>> 1e464c8 (feat: Refactor for NMAX and change setup)
        }

        (inP2P, onPool) = positionsManager.supplyBalanceInOf(aDai, address(supplier1));
        expectedInP2P = p2pUnitToUnderlying(amount, p2pExchangeRate);

<<<<<<< HEAD
        testEquality(inP2P, expectedInP2P);
        testEquality(onPool, 0);
=======
        assertLe(get_abs_diff(inP2P, expectedInP2P), 2);
        assertLe(get_abs_diff(onPool, 0), 2);
>>>>>>> 1e464c8 (feat: Refactor for NMAX and change setup)
    }

    // 1.6 - The NMAX biggest borrowers don't match all of the supplied amount, after NMAX match, the rest is supplied and set `onPool`.
    // ⚠️ most gas expensive supply scenario.
    function testSupply_1_6() public {
<<<<<<< HEAD
        uint256 amount = 10000 ether;
=======
        uint256 amount = 100 ether;
>>>>>>> 1e464c8 (feat: Refactor for NMAX and change setup)
        uint256 collateral = 2 * amount;

        setNMAXAndCreateSigners(20);
        uint256 NMAX = positionsManager.NMAX();

        uint256 amountPerBorrower = amount / (2 * NMAX);

        for (uint256 i = 0; i < NMAX; i++) {
            borrowers[i].approve(usdc, to6Decimals(collateral));
            borrowers[i].supply(aUsdc, to6Decimals(collateral));

            borrowers[i].borrow(aDai, amountPerBorrower);
        }

        supplier1.approve(dai, amount);
        supplier1.supply(aDai, amount);

        uint256 inP2P;
        uint256 onPool;
        uint256 expectedInP2P;
        uint256 p2pExchangeRate = marketsManager.p2pExchangeRate(aDai);
        uint256 normalizedIncome = lendingPool.getReserveNormalizedIncome(dai);

        for (uint256 i = 0; i < NMAX; i++) {
            (inP2P, onPool) = positionsManager.borrowBalanceInOf(aDai, address(borrowers[i]));

            expectedInP2P = p2pUnitToUnderlying(inP2P, p2pExchangeRate);

<<<<<<< HEAD
            testEquality(expectedInP2P, amountPerBorrower);
            testEquality(onPool, 0);
=======
            assertEq(expectedInP2P, amountPerBorrower);
            assertEq(onPool, 0);
>>>>>>> 1e464c8 (feat: Refactor for NMAX and change setup)
        }

        (inP2P, onPool) = positionsManager.supplyBalanceInOf(aDai, address(supplier1));

        expectedInP2P = p2pUnitToUnderlying(amount / 2, p2pExchangeRate);
        uint256 expectedOnPool = underlyingToAdUnit(amount / 2, normalizedIncome);

<<<<<<< HEAD
        testEquality(inP2P, expectedInP2P);
        testEquality(onPool, expectedOnPool);
=======
        assertLe(get_abs_diff(inP2P, expectedInP2P), 3);
        assertLe(get_abs_diff(onPool, expectedOnPool), 3);
>>>>>>> 1e464c8 (feat: Refactor for NMAX and change setup)
    }
}
