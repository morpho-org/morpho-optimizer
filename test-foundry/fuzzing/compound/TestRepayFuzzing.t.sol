// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.13;

import "./setup/TestSetupFuzzing.sol";

contract TestRepayFuzzing is TestSetupFuzzing {
    using CompoundMath for uint256;

    // Simple repay on pool.
    function testRepay1Fuzzed(
        uint128 _supplied,
        uint8 _suppliedAsset,
        uint8 _borrowedAsset,
        uint8 _firstRandom,
        uint8 _secondRandom
    ) public {
        (address suppliedAsset, address suppliedUnderlying) = getAsset(_suppliedAsset);
        (address borrowedAsset, address borrowedUnderlying) = getAsset(_borrowedAsset);

        uint256 supplied = _supplied;

        hevm.assume(
            supplied != 0 &&
                supplied <
                ERC20(suppliedUnderlying).balanceOf(address(supplier1)) /
                    10**(ERC20(suppliedUnderlying).decimals()) &&
                _firstRandom != 0 &&
                _secondRandom != 0
        );

        borrower1.approve(suppliedUnderlying, supplied);
        borrower1.supply(suppliedAsset, supplied);

        (, uint256 borrowable) = lens.getUserMaxCapacitiesForAsset(
            address(borrower1),
            borrowedAsset
        );

        uint256 borrowedAmount = (borrowable * _firstRandom) / 255;
        hevm.assume(borrowedAmount != 0);
        borrower1.borrow(borrowedAsset, borrowedAmount);

        uint256 repaidAmount = (borrowedAmount * _secondRandom) / 255;
        hevm.assume(repaidAmount != 0);
        borrower1.approve(borrowedUnderlying, repaidAmount);
        borrower1.repay(borrowedAsset, repaidAmount);
    }

    // Partially matched with one borrower waiting.
    function testRepay2Fuzzed(
        uint128 _supplied,
        uint8 _suppliedAsset,
        uint8 _borrowedAsset,
        uint8 _firstRandom,
        uint8 _secondRandom,
        uint8 _thirdRandom
    ) public {
        (address suppliedAsset, address suppliedUnderlying) = getAsset(_suppliedAsset);
        (address borrowedAsset, address borrowedUnderlying) = getAsset(_borrowedAsset);

        uint256 supplied = _supplied;

        hevm.assume(
            supplied != 0 &&
                supplied <
                ERC20(suppliedUnderlying).balanceOf(address(supplier1)) /
                    10**(ERC20(suppliedUnderlying).decimals()) &&
                _firstRandom != 0 &&
                _secondRandom != 0 &&
                _thirdRandom != 0
        );

        borrower1.approve(suppliedUnderlying, supplied);
        borrower1.supply(suppliedAsset, supplied);

        (, uint256 borrowable) = lens.getUserMaxCapacitiesForAsset(
            address(borrower1),
            borrowedAsset
        );

        // Borrower1 borrow borrowedAmount.
        uint256 borrowedAmount = (borrowable * _firstRandom) / 255;
        hevm.assume(borrowedAmount != 0);
        borrower1.borrow(borrowedAsset, borrowedAmount);

        // He is matched up to matched amount with supplier1.
        uint256 matchedAmount = (borrowedAmount * _secondRandom) / 255;
        hevm.assume(matchedAmount != 0);
        supplier1.approve(borrowedUnderlying, matchedAmount);
        supplier1.supply(borrowedAsset, matchedAmount);

        // Borrower2 has his debt waiting on pool.
        borrower2.approve(suppliedUnderlying, supplied);
        borrower2.supply(suppliedAsset, supplied);
        borrower2.borrow(borrowedAsset, borrowedAmount);

        // Borrower1 repays a random amount.
        uint256 repaidAmount = (borrowedAmount * _thirdRandom) / 255;
        hevm.assume(repaidAmount != 0);
        borrower1.approve(borrowedUnderlying, repaidAmount);
        borrower1.repay(borrowedAsset, repaidAmount);
    }

    // Matched, with random number of borrower await on pool to replace.
    function testRepay3Fuzzed(
        uint128 _suppliedAmount,
        uint8 _suppliedAsset,
        uint8 _borrowedAsset,
        uint8 _firstRandom,
        uint8 _secondRandom,
        uint8 _thirdRandom
    ) public {
        (address suppliedAsset, address suppliedUnderlying) = getAsset(_suppliedAsset);
        (address borrowedAsset, address borrowedUnderlying) = getAsset(_borrowedAsset);

        uint256 suppliedAmount = _suppliedAmount;

        hevm.assume(
            suppliedAmount != 0 &&
                suppliedAmount <
                ERC20(suppliedUnderlying).balanceOf(address(supplier1)) /
                    10**(ERC20(suppliedUnderlying).decimals()) &&
                _firstRandom != 0 &&
                _secondRandom != 0 &&
                _thirdRandom != 0
        );

        borrower1.approve(suppliedUnderlying, suppliedAmount);
        borrower1.supply(suppliedAsset, suppliedAmount);

        (, uint256 borrowable) = lens.getUserMaxCapacitiesForAsset(
            address(borrower1),
            borrowedAsset
        );

        // Borrower1 borrow borrowedAmount.
        uint256 borrowedAmount = (borrowable * _firstRandom) / 255;
        hevm.assume(borrowedAmount > 25);
        borrower1.borrow(borrowedAsset, borrowedAmount);

        // He is matched with supplier1.
        supplier1.approve(borrowedUnderlying, borrowedAmount);
        supplier1.supply(borrowedAsset, borrowedAmount);

        // There is a random number of waiting borrower on pool.
        uint256 nbOfWaitingBorrower = ((20 * uint256(_secondRandom)) / 255) + 1;
        createSigners(nbOfWaitingBorrower);
        uint256 amountPerBorrower = borrowedAmount / nbOfWaitingBorrower;
        for (uint256 i = 2; i < nbOfWaitingBorrower; i++) {
            borrowers[i].approve(suppliedUnderlying, suppliedAmount);
            borrowers[i].supply(suppliedAsset, suppliedAmount);
            borrowers[i].borrow(borrowedAsset, amountPerBorrower);
        }

        // Borrower1 repays a random amount.
        uint256 repaidAmount = (borrowedAmount * _thirdRandom) / 255;
        hevm.assume(repaidAmount != 0);
        borrower1.approve(borrowedUnderlying, repaidAmount);
        borrower1.repay(borrowedAsset, repaidAmount);
    }

    function testRepay4Fuzzed(
        uint128 _borrowAmount,
        // uint256 _proportionMatched,
        uint8 _borrowedAsset,
        uint8 _collateralAsset
    ) public {
        (address collateralCToken, address collateralUnderlying) = getAsset(_collateralAsset);
        (address borrowedCToken, address borrowedUnderlying) = getAsset(_borrowedAsset);
        setDefaultMaxGasForMatchingHelper(
            type(uint64).max,
            type(uint64).max,
            type(uint64).max,
            type(uint64).max
        );
        uint256 collatToSupply = ERC20(collateralUnderlying).balanceOf(address(borrower1));
        borrower1.approve(collateralUnderlying, collatToSupply);
        borrower1.supply(collateralCToken, collatToSupply);
        assumeBorrowAmountIsCorrect(borrowedCToken, _borrowAmount);
        assumeBorrowable(borrower1, borrowedCToken, _borrowAmount);
        borrower1.borrow(borrowedCToken, _borrowAmount);
        uint256 matchersAmountToSupply = _borrowAmount / (2 * NMAX);
        assumeSupplyAmountIsCorrect(borrowedUnderlying, matchersAmountToSupply);
        createSigners(2 * NMAX);
        for (uint256 i; i < 2 * NMAX; i++) {
            suppliers[i].approve(borrowedUnderlying, matchersAmountToSupply);
            suppliers[i].supply(borrowedCToken, matchersAmountToSupply);
        }
        for (uint256 j = 1; j <= NMAX; j++) {
            borrowers[j].approve(collateralUnderlying, collatToSupply);
            borrowers[j].supply(collateralCToken, collatToSupply);
            borrowers[j].borrow(borrowedCToken, matchersAmountToSupply);
        }
        borrower1.approve(borrowedUnderlying, type(uint256).max);
        borrower1.repay(borrowedCToken, type(uint256).max);
    }

    function testTemp() public {
        console.log(wEth);
    }

    function testDeltaRepayFuzzed() public {}

    function assumeBorrowable(
        User _user,
        address market,
        uint256 amount
    ) internal {
        (, uint256 borrowable) = lens.getUserMaxCapacitiesForAsset(address(_user), market);
        hevm.assume(amount <= borrowable);
    }
}
