// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WadMath} from "./libraries/WadMath.sol";
import {RwaStressLib} from "./RwaStressLib.sol";

/// @title SpanMathLib
/// @notice 16-scenario SPAN grid for the base legs plus the full three-class portfolio snapshot.
/// @dev Pure functions only. The TS mirror in `ts-mirror/src/spanMath.ts` must match exactly.
library SpanMathLib {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant HC_STOCK = 0.85e18;
    uint256 internal constant HC_LP = 0.70e18;
    uint256 internal constant HC_R1 = 0.75e18;
    uint256 internal constant HC_R2 = 0.85e18;
    uint256 internal constant LTV_MAX = 0.80e18;
    uint256 internal constant MAINT = 0.85e18;
    uint256 internal constant LP_BETA = 0.8e18;
    uint256 internal constant LP_CONVEX = 0.05e18;
    uint256 internal constant FEE_CREDIT_CAP = 0.10e18;
    uint256 internal constant HALF = 0.5e18;

    struct Legs {
        uint256 stockAmt;
        uint256 stockMark;
        uint256 lpAmt;
        uint256 lpMark;
        uint256 feeCreditBase;
        uint256 debt;
        bool nonEmpty;
    }

    struct PortfolioResult {
        uint256 im;
        uint256 bp;
        uint256 health;
        uint256 cStressed;
        uint256 unwindableNow;
        uint256 earningLocked;
        uint256 feeCreditBase;
        uint256 lossR1Base;
        uint256 lossR2;
        uint8 eligR1;
        uint8 eligR2;
        uint256[16] scenarioLosses;
    }

    function shocks() internal pure returns (int256[8] memory s) {
        s[0] = -0.20e18;
        s[1] = -0.10e18;
        s[2] = -0.05e18;
        s[3] = -0.02e18;
        s[4] = 0.02e18;
        s[5] = 0.05e18;
        s[6] = 0.10e18;
        s[7] = 0.20e18;
    }

    function vols() internal pure returns (uint256[2] memory v) {
        v[0] = 1.0e18;
        v[1] = 1.5e18;
    }

    /// @notice Base-leg SPAN snapshot (leg ST + leg LP).
    function accountSnapshot(Legs memory l)
        internal
        pure
        returns (uint256 im, uint256 bp, uint256 health, uint256[16] memory scenarioLosses)
    {
        uint256 stockUsd = l.stockAmt.mulWad(l.stockMark);
        uint256 lpUsd = l.lpAmt.mulWad(l.lpMark);
        return accountSnapshotUsd(stockUsd, lpUsd, l.feeCreditBase, l.debt);
    }

    /// @notice Base-leg SPAN snapshot from already-normalized USD-WAD values.
    function accountSnapshotUsd(uint256 stockUsd, uint256 lpUsd, uint256 feeCreditBase, uint256 debt)
        internal
        pure
        returns (uint256 im, uint256 bp, uint256 health, uint256[16] memory scenarioLosses)
    {
        int256[8] memory shocks_ = shocks();
        uint256[2] memory vols_ = vols();
        uint256 maxIm;

        for (uint256 i = 0; i < 8; i++) {
            for (uint256 j = 0; j < 2; j++) {
                int256 sh = (shocks_[i] * int256(vols_[j])) / int256(WAD);
                uint256 idx = i * 2 + j;
                uint256 absSh = sh < 0 ? uint256(-sh) : uint256(sh);

                uint256 lossStock = sh < 0 ? uint256(-sh).mulWad(stockUsd) : 0;
                uint256 beta = LP_BETA.mulWad(absSh) + LP_CONVEX.mulWad(absSh.mulWad(absSh));
                uint256 lossLp = lpUsd.mulWad(beta);
                uint256 gross = lossStock + lossLp;
                uint256 feeCred = sh < 0 ? feeCreditBase.mulWad(HALF) : feeCreditBase;
                uint256 required = gross > feeCred ? gross - feeCred : 0;

                scenarioLosses[idx] = gross;
                if (required > maxIm) maxIm = required;
            }
        }

        im = maxIm;
        uint256 collateral = stockUsd.mulWad(HC_STOCK) + lpUsd.mulWad(HC_LP);
        uint256 cStress = collateral > im ? collateral - im : 0;
        bp = cStress.mulWad(LTV_MAX);
        uint256 denom = debt > 1e12 ? debt : 1e12;
        health = cStress.divWad(denom);
    }

    /// @notice Full three-class portfolio snapshot. R2 terms use the closed form, not a 16x loop.
    function portfolioSnapshotUsd(
        uint256 stockUsd,
        uint256 lpUsd,
        uint256 equityRwaUsd,
        uint256 navUsd,
        uint256 feeCreditFees,
        uint256 navAccrualCredit,
        uint256 dailyCoupon,
        uint256 debt,
        bool transferRestricted,
        bool gateOpen,
        uint256 dailyCap
    ) internal pure returns (PortfolioResult memory r) {
        uint256 totalCollateral = stockUsd + lpUsd + equityRwaUsd + navUsd;
        uint256 feeCap = totalCollateral.mulWad(FEE_CREDIT_CAP);
        uint256 combinedCredit = feeCreditFees + navAccrualCredit;
        r.feeCreditBase = combinedCredit < feeCap ? combinedCredit : feeCap;

        (r.eligR1, r.eligR2) =
            RwaStressLib.eligibility(transferRestricted, gateOpen, navUsd, dailyCap);
        (r.lossR1Base, r.lossR2) =
            RwaStressLib.rwaStress(equityRwaUsd, navUsd, dailyCoupon, WAD);

        int256[8] memory shocks_ = shocks();
        uint256[2] memory vols_ = vols();
        uint256 maxIm;

        for (uint256 i = 0; i < 8; i++) {
            for (uint256 j = 0; j < 2; j++) {
                int256 sh = (shocks_[i] * int256(vols_[j])) / int256(WAD);
                uint256 idx = i * 2 + j;
                uint256 absSh = sh < 0 ? uint256(-sh) : uint256(sh);

                uint256 lossStock = sh < 0 ? uint256(-sh).mulWad(stockUsd) : 0;
                uint256 beta = LP_BETA.mulWad(absSh) + LP_CONVEX.mulWad(absSh.mulWad(absSh));
                uint256 lossLp = lpUsd.mulWad(beta);
                uint256 lossR1 = r.lossR1Base.mulWad(vols_[j]);
                uint256 gross = lossStock + lossLp + lossR1 + r.lossR2;
                uint256 feeCred = sh < 0 ? r.feeCreditBase.mulWad(HALF) : r.feeCreditBase;
                uint256 required = gross > feeCred ? gross - feeCred : 0;

                r.scenarioLosses[idx] = gross;
                if (required > maxIm) maxIm = required;
            }
        }

        r.im = maxIm;
        uint256 collateral = stockUsd.mulWad(HC_STOCK) + lpUsd.mulWad(HC_LP)
            + equityRwaUsd.mulWad(HC_R1) + navUsd.mulWad(HC_R2);
        r.cStressed = collateral > r.im ? collateral - r.im : 0;
        r.bp = r.cStressed.mulWad(LTV_MAX);

        uint256 denom = debt > 1e12 ? debt : 1e12;
        r.health = r.cStressed.divWad(denom);

        (r.unwindableNow, r.earningLocked) = RwaStressLib.segregated(
            stockUsd, lpUsd, equityRwaUsd, navUsd, r.eligR1, r.eligR2
        );
    }
}
