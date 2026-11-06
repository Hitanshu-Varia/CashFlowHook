// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WadMath} from "./libraries/WadMath.sol";

/// @title FeeMathLib
/// @notice Cashflow underwriting math: trailing fee average, Sybil/vol/drawdown haircuts,
///         combined fee-credit cap input, and the StrategyBureau score.
/// @dev Pure. Mirrored by `ts-mirror/src/feeMath.ts`.
library FeeMathLib {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant EARNINGS_MULTIPLIER = 3e18;
    uint256 internal constant TAKER_FLOOR = 5;
    uint256 internal constant TAKER_SCALE = 20;
    uint256 internal constant VOL_PENALTY = 0.5e18;
    uint256 internal constant DD_PENALTY = 0.3e18;
    uint256 internal constant SCORE_WAD = 100e18;

    function avg7d(uint256[7] memory dailyFees) internal pure returns (uint256) {
        uint256 sum;
        for (uint256 i = 0; i < 7; i++) {
            sum += dailyFees[i];
        }
        return sum / 7;
    }

    function sigmaN(uint256[7] memory dailyFees, uint256 mean) internal pure returns (uint256) {
        if (mean == 0) return 0;
        uint256 variance;
        for (uint256 i = 0; i < 7; i++) {
            uint256 diff = dailyFees[i] > mean ? dailyFees[i] - mean : mean - dailyFees[i];
            variance += diff.mulWad(diff);
        }
        variance /= 7;
        uint256 sigma = variance.sqrt();
        uint256 normalized = sigma.divWad(mean);
        return normalized > WAD ? WAD : normalized;
    }

    function drawdownN(uint256[7] memory dailyFees) internal pure returns (uint256) {
        uint256 peak;
        uint256 maxDd;
        for (uint256 i = 0; i < 7; i++) {
            if (dailyFees[i] > peak) peak = dailyFees[i];
            if (peak > 0) {
                uint256 dd = peak > dailyFees[i] ? (peak - dailyFees[i]).divWad(peak) : 0;
                if (dd > maxDd) maxDd = dd;
            }
        }
        return maxDd > WAD ? WAD : maxDd;
    }

    /// @notice Fee earnings credit before the combined 10%-of-collateral cap.
    function feeCreditFees(uint256[7] memory dailyFees, uint256 distinctTakers)
        internal
        pure
        returns (uint256)
    {
        if (distinctTakers < TAKER_FLOOR) return 0;

        uint256 mean = avg7d(dailyFees);
        if (mean == 0) return 0;

        uint256 takerFactor = distinctTakers >= TAKER_SCALE
            ? WAD
            : distinctTakers.divWad(TAKER_SCALE);
        uint256 volPenalty = WAD - VOL_PENALTY.mulWad(sigmaN(dailyFees, mean));
        uint256 ddPenalty = WAD - DD_PENALTY.mulWad(drawdownN(dailyFees));

        uint256 credit = mean * 3;
        credit = credit.mulWad(takerFactor);
        credit = credit.mulWad(volPenalty);
        credit = credit.mulWad(ddPenalty);
        return credit;
    }

    /// @notice StrategyScore, 0-100, gated by the distinct-taker floor.
    function strategyScore(uint256[7] memory dailyFees, uint256 distinctTakers, uint256 ageDays)
        internal
        pure
        returns (uint16)
    {
        if (distinctTakers < TAKER_FLOOR) return 0;

        uint256 mean = avg7d(dailyFees);
        uint256 sigma = sigmaN(dailyFees, mean);
        uint256 dd = drawdownN(dailyFees);
        uint256 ageFactor = ageDays >= 7 ? WAD : ageDays.divWad(7);

        uint256 raw = HALF().mulWad(WAD - sigma) + uint256(0.3e18).mulWad(WAD - dd)
            + uint256(0.2e18).mulWad(ageFactor);
        uint256 scoreWad = raw.mulWad(SCORE_WAD);
        uint256 rounded = (scoreWad + 0.5e18) / WAD;
        if (rounded > 100) rounded = 100;
        return uint16(rounded);
    }

    function HALF() internal pure returns (uint256) {
        return 0.5e18;
    }

    /// @notice Combined cap applied to fee credit + NAV accrual credit in the engine.
    function combinedCredit(uint256 feeCredit, uint256 navAccrualCredit, uint256 totalCollateralUsd)
        internal
        pure
        returns (uint256)
    {
        uint256 cap = totalCollateralUsd.mulWad(0.10e18);
        uint256 combined = feeCredit + navAccrualCredit;
        return combined < cap ? combined : cap;
    }
}
