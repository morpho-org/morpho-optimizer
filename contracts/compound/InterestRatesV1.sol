// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.13;

import "./interfaces/IInterestRates.sol";

import "./libraries/CompoundMath.sol";
import "./libraries/Types.sol";

contract InterestRatesV1 is IInterestRates {
    using CompoundMath for uint256;

    /// STRUCT ///

    struct Vars {
        uint256 shareOfTheDelta; // Share of delta in the total P2P amount.
        uint256 supplyP2PGrowthFactor; // Supply growth factor (between now and the last update).
        uint256 borrowP2PGrowthFactor; // Borrow growth factor (between now and the last update).
        uint256 supplyPoolGrowthFactor; // Borrow growth factor (between now and the last update).
        uint256 borrowPoolGrowthFactor; // Borrow growth factor (between now and the last update).
    }

    /// STORAGE ///

    uint256 public constant MAX_BASIS_POINTS = 10_000; // 100% (in basis point).

    /// EXTERNAL ///

    /// @notice Computes and return new P2P exchange rates.
    /// @param _params Computations parameters.
    /// @return newSupplyP2PExchangeRate The updated supplyP2PExchangeRate.
    /// @return newBorrowP2PExchangeRate The updated borrowP2PExchangeRate.
    function computeP2PExchangeRates(Types.Params memory _params)
        public
        pure
        returns (uint256 newSupplyP2PExchangeRate, uint256 newBorrowP2PExchangeRate)
    {
        Vars memory vars;
        (
            vars.supplyP2PGrowthFactor,
            vars.borrowP2PGrowthFactor,
            vars.supplyPoolGrowthFactor,
            vars.borrowPoolGrowthFactor
        ) = _computeGrowthFactors(
            _params.poolSupplyExchangeRate,
            _params.poolBorrowExchangeRate,
            _params.lastPoolSupplyExchangeRate,
            _params.lastPoolBorrowExchangeRate,
            _params.reserveFactor
        );

        if (_params.delta.supplyP2PAmount == 0 || _params.delta.supplyP2PDelta == 0) {
            newSupplyP2PExchangeRate = _params.supplyP2PExchangeRate.mul(
                vars.supplyP2PGrowthFactor
            );
        } else {
            vars.shareOfTheDelta = CompoundMath.min(
                _params
                .delta
                .supplyP2PDelta
                .mul(_params.poolSupplyExchangeRate)
                .div(_params.supplyP2PExchangeRate)
                .div(_params.delta.supplyP2PAmount),
                CompoundMath.wad() // To avoid shareOfTheDelta > 1 with rounding errors.
            );

            newSupplyP2PExchangeRate = _params.supplyP2PExchangeRate.mul(
                (CompoundMath.wad() - vars.shareOfTheDelta).mul(vars.supplyP2PGrowthFactor) +
                    vars.shareOfTheDelta.mul(vars.supplyPoolGrowthFactor)
            );
        }

        if (_params.delta.borrowP2PAmount == 0 || _params.delta.borrowP2PDelta == 0) {
            newBorrowP2PExchangeRate = _params.borrowP2PExchangeRate.mul(
                vars.borrowP2PGrowthFactor
            );
        } else {
            vars.shareOfTheDelta = CompoundMath.min(
                _params
                .delta
                .borrowP2PDelta
                .mul(_params.poolBorrowExchangeRate)
                .div(_params.borrowP2PExchangeRate)
                .div(_params.delta.borrowP2PAmount),
                CompoundMath.wad() // To avoid shareOfTheDelta > 1 with rounding errors.
            );

            newBorrowP2PExchangeRate = _params.borrowP2PExchangeRate.mul(
                (CompoundMath.wad() - vars.shareOfTheDelta).mul(vars.borrowP2PGrowthFactor) +
                    vars.shareOfTheDelta.mul(vars.borrowPoolGrowthFactor)
            );
        }
    }

    /// @notice Computes and returns supply P2P growthfactor and borrow P2P growthfactor.
    /// @param _poolSupplyExchangeRate The current pool supply exchange rate.
    /// @param _poolBorrowExchangeRate The current pool borrow exchange rate.
    /// @param _lastPoolSupplyExchangeRate The pool supply exchange rate at last update.
    /// @param _lastPoolBorrowExchangeRate The pool borrow exchange rate at last update.
    /// @param _reserveFactor The reserve factor percentage (10 000 = 100%).
    /// @return supplyP2PGrowthFactor The supply P2P growthfactor.
    /// @return borrowP2PGrowthFactor The borrow P2P growthfactor.
    /// @return supplyPoolGrowthFactor The supply pool growthfactor.
    /// @return borrowPoolGrowthFactor The borrow pool growthfactor.
    function _computeGrowthFactors(
        uint256 _poolSupplyExchangeRate,
        uint256 _poolBorrowExchangeRate,
        uint256 _lastPoolSupplyExchangeRate,
        uint256 _lastPoolBorrowExchangeRate,
        uint256 _reserveFactor
    )
        internal
        pure
        returns (
            uint256 supplyP2PGrowthFactor,
            uint256 borrowP2PGrowthFactor,
            uint256 supplyPoolGrowthFactor,
            uint256 borrowPoolGrowthFactor
        )
    {
        supplyPoolGrowthFactor = _poolSupplyExchangeRate.div(_lastPoolSupplyExchangeRate);
        borrowPoolGrowthFactor = _poolBorrowExchangeRate.div(_lastPoolBorrowExchangeRate);
        supplyP2PGrowthFactor =
            ((MAX_BASIS_POINTS - _reserveFactor) *
                (2 * supplyPoolGrowthFactor + borrowPoolGrowthFactor)) /
            3 /
            MAX_BASIS_POINTS +
            (_reserveFactor * supplyPoolGrowthFactor) /
            MAX_BASIS_POINTS;

        borrowP2PGrowthFactor =
            ((MAX_BASIS_POINTS - _reserveFactor) *
                (2 * supplyPoolGrowthFactor + borrowPoolGrowthFactor)) /
            3 /
            MAX_BASIS_POINTS +
            (_reserveFactor * borrowPoolGrowthFactor) /
            MAX_BASIS_POINTS;
    }
}
