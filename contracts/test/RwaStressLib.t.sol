// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RwaStressLib} from "../src/RwaStressLib.sol";

contract RwaStressLibTest is Test {
    function test_lossR1() public pure {
        (uint256 lossR1,) = RwaStressLib.rwaStress(1000e18, 0, 0, 1.0e18);
        assertEq(lossR1, 300e18);

        (uint256 lossR1Vol,) = RwaStressLib.rwaStress(1000e18, 0, 0, 1.5e18);
        assertEq(lossR1Vol, 450e18);
    }

    function test_lossR2() public pure {
        (, uint256 lossR2) = RwaStressLib.rwaStress(0, 1000e18, 86.4e18, 1.0e18);
        // 1.5% permissioned-liquidity haircut + min(0.5% NAV, 2 days of coupon)
        assertEq(lossR2, 20e18);
    }

    function test_lossR2CouponBinds() public pure {
        (, uint256 lossR2) = RwaStressLib.rwaStress(0, 1000e18, 1e18, 1.0e18);
        // 15 + min(5, 2) = 17
        assertEq(lossR2, 17e18);
    }

    function test_eligibility() public pure {
        (uint8 r1, uint8 r2) = RwaStressLib.eligibility(false, true, 1000e18, 25_000_000e18);
        assertEq(r1, 1);
        assertEq(r2, 1);

        (r1, r2) = RwaStressLib.eligibility(true, true, 1000e18, 25_000_000e18);
        assertEq(r1, 0);
        assertEq(r2, 1);

        (r1, r2) = RwaStressLib.eligibility(false, false, 1000e18, 25_000_000e18);
        assertEq(r1, 1);
        assertEq(r2, 0);
    }

    function test_eligibilityCapBoundary() public pure {
        uint256 cap = 25_000_000e18;
        uint256 limit = cap / 4; // capFraction = 25%
        (, uint8 atLimit) = RwaStressLib.eligibility(false, true, limit, cap);
        (, uint8 aboveLimit) = RwaStressLib.eligibility(false, true, limit + 1, cap);
        assertEq(atLimit, 1);
        assertEq(aboveLimit, 0);
    }

    function test_segregation() public pure {
        (uint256 unwindable, uint256 locked) =
            RwaStressLib.segregated(1000e18, 1000e18, 1000e18, 1000e18, 1, 1);
        assertEq(unwindable, 3150e18);
        assertEq(locked, 0);

        (unwindable, locked) =
            RwaStressLib.segregated(1000e18, 1000e18, 1000e18, 1000e18, 0, 0);
        assertEq(unwindable, 1550e18);
        assertEq(locked, 1600e18);
    }

    function testFuzz_unwindableNeverAboveTotal(
        uint256 stock,
        uint256 lp,
        uint256 r1,
        uint256 r2,
        bool restricted,
        bool gate
    ) public pure {
        stock = bound(stock, 0, 1e30);
        lp = bound(lp, 0, 1e30);
        r1 = bound(r1, 0, 1e30);
        r2 = bound(r2, 0, 1e30);
        (uint8 e1, uint8 e2) = RwaStressLib.eligibility(restricted, gate, r2, 25_000_000e18);
        (uint256 unwindable, uint256 locked) = RwaStressLib.segregated(stock, lp, r1, r2, e1, e2);
        uint256 total = stock * 0.85e18 / 1e18 + lp * 0.70e18 / 1e18 + r1 * 0.75e18 / 1e18
            + r2 * 0.85e18 / 1e18;
        assertLe(unwindable, total);
        assertEq(unwindable + locked, total);
    }
}
