// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WadMath} from "./libraries/WadMath.sol";

/// @title RwaStressLib
/// @notice Closed-form stress terms and margin segregation for the two RWA collateral classes.
/// @dev Pure functions only: no storage, no external calls. Mirrored byte-for-byte by
///      `ts-mirror/src/rwaStress.ts`.
library RwaStressLib {
    using WadMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant HC_R1 = 0.75e18;
    uint256 internal constant HC_R2 = 0.85e18;
    uint256 internal constant GAP_PREMIUM = 0.5e18;
    uint256 internal constant PERM_LIQ_HC = 0.015e18;
    uint256 internal constant EXIT_COST_NAV = 0.005e18;
    uint256 internal constant GATE_DAYS = 2;
    uint256 internal constant CAP_FRACTION = 0.25e18;
    uint256 internal constant SHOCK_20 = 0.20e18;

    /// @notice Worst-shock equity gap loss and treasury permissioned-liquidity loss.
    /// @param equityRwaUsd R1 leg value in USD-WAD.
    /// @param navUsd R2 leg value in USD-WAD.
    /// @param dailyCoupon NAV accrual per day in USD-WAD.
    /// @param volMul Volatility multiplier (1.0e18 or 1.5e18).
    function rwaStress(uint256 equityRwaUsd, uint256 navUsd, uint256 dailyCoupon, uint256 volMul)
        internal
        pure
        returns (uint256 lossR1, uint256 lossR2)
    {
        // lossR1 = equityUsd * 0.20 * (1 + GAP_PREMIUM) * volMul
        lossR1 = equityRwaUsd.mulWad(SHOCK_20).mulWad(WAD + GAP_PREMIUM).mulWad(volMul);
        // lossR2 = navUsd * PERM_LIQ_HC + min(navUsd * 0.5%, dailyCoupon * gateDays)
        uint256 perm = navUsd.mulWad(PERM_LIQ_HC);
        uint256 exitCost = navUsd.mulWad(EXIT_COST_NAV);
        uint256 couponCost = dailyCoupon * GATE_DAYS;
        lossR2 = perm + (exitCost < couponCost ? exitCost : couponCost);
    }

    /// @notice Segregation eligibility flags.
    /// @param transferRestricted R1 transfer restriction flag.
    /// @param gateOpen R2 redemption gate state.
    /// @param navUsd R2 leg value in USD-WAD.
    /// @param dailyCap Daily per-investor instant redemption cap in USD-WAD.
    function eligibility(bool transferRestricted, bool gateOpen, uint256 navUsd, uint256 dailyCap)
        internal
        pure
        returns (uint8 eligR1, uint8 eligR2)
    {
        eligR1 = transferRestricted ? 0 : 1;
        uint256 capLimit = dailyCap.mulWad(CAP_FRACTION);
        eligR2 = (gateOpen && navUsd <= capLimit) ? 1 : 0;
    }

    /// @notice Split haircut collateral into instantly unwindable and earning-but-locked.
    function segregated(
        uint256 stockUsd,
        uint256 lpUsd,
        uint256 equityRwaUsd,
        uint256 navUsd,
        uint8 eligR1,
        uint8 eligR2
    ) internal pure returns (uint256 unwindableNow, uint256 earningLocked) {
        uint256 stockHc = stockUsd.mulWad(0.85e18);
        uint256 lpHc = lpUsd.mulWad(0.70e18);
        uint256 r1Hc = equityRwaUsd.mulWad(HC_R1);
        uint256 r2Hc = navUsd.mulWad(HC_R2);

        unwindableNow = stockHc + lpHc;
        if (eligR1 == 1) unwindableNow += r1Hc;
        if (eligR2 == 1) unwindableNow += r2Hc;

        earningLocked = (stockHc + lpHc + r1Hc + r2Hc) - unwindableNow;
    }
}
