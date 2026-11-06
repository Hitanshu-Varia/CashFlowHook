// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpanMathLib} from "../src/SpanMathLib.sol";
import {WadMath} from "../src/libraries/WadMath.sol";

contract SpanMathLibTest is Test {
    using WadMath for uint256;

    function test_zeroPortfolio() public pure {
        (uint256 im, uint256 bp, uint256 health, uint256[16] memory losses) =
            SpanMathLib.accountSnapshotUsd(0, 0, 0, 0);
        assertEq(im, 0);
        assertEq(bp, 0);
        assertEq(health, 0);
        for (uint256 i = 0; i < 16; i++) assertEq(losses[i], 0);
    }

    function test_stockOnlyGrid() public pure {
        (uint256 im, uint256 bp,, uint256[16] memory losses) =
            SpanMathLib.accountSnapshotUsd(1000e18, 0, 0, 0);

        assertEq(im, 300e18);
        assertEq(bp, 440e18);
        assertEq(losses[0], 200e18);
        assertEq(losses[1], 300e18);
        assertEq(losses[2], 100e18);
        assertEq(losses[3], 150e18);
        assertEq(losses[4], 50e18);
        assertEq(losses[5], 75e18);
        assertEq(losses[6], 20e18);
        assertEq(losses[7], 30e18);
        for (uint256 i = 8; i < 16; i++) assertEq(losses[i], 0);
    }

    function test_lpOnlyGrid() public pure {
        (uint256 im, uint256 bp,,) = SpanMathLib.accountSnapshotUsd(0, 1000e18, 0, 0);
        assertEq(im, 244.5e18);
        assertEq(bp, 364.4e18);
    }

    function test_baseTwoLegs() public pure {
        (uint256 im, uint256 bp,,) = SpanMathLib.accountSnapshotUsd(1000e18, 1000e18, 0, 0);
        assertEq(im, 544.5e18);
        assertEq(bp, 804.4e18);
    }

    function test_feeCreditLowersIm() public pure {
        (uint256 noFee,,,) = SpanMathLib.accountSnapshotUsd(1000e18, 0, 0, 0);
        (uint256 withFee,,,) = SpanMathLib.accountSnapshotUsd(1000e18, 0, 100e18, 0);
        assertEq(noFee, 300e18);
        assertEq(withFee, 250e18);
    }

    function test_fullPortfolio() public pure {
        SpanMathLib.PortfolioResult memory r = SpanMathLib.portfolioSnapshotUsd(
            1000e18,
            1000e18,
            1000e18,
            1000e18,
            0,
            0,
            86.4e18,
            0,
            false,
            true,
            25_000_000e18
        );

        assertEq(r.lossR1Base, 300e18);
        assertEq(r.lossR2, 20e18);
        assertEq(r.im, 1014.5e18);
        assertEq(r.cStressed, 2135.5e18);
        assertEq(r.bp, 1708.4e18);
        assertEq(r.eligR1, 1);
        assertEq(r.eligR2, 1);
        assertEq(r.unwindableNow, 3150e18);
        assertEq(r.earningLocked, 0);
    }

    function test_fullPortfolioSegregated() public pure {
        SpanMathLib.PortfolioResult memory r = SpanMathLib.portfolioSnapshotUsd(
            1000e18, 1000e18, 1000e18, 1000e18, 0, 0, 86.4e18, 0, true, false, 25_000_000e18
        );
        assertEq(r.eligR1, 0);
        assertEq(r.eligR2, 0);
        assertEq(r.unwindableNow, 1550e18);
        assertEq(r.earningLocked, 1600e18);
        // Locked collateral still backs BP; only the unwind path is restricted.
        assertEq(r.bp, 1708.4e18);
    }

    function testFuzz_bpNeverAboveLtvHaircut(uint256 stockUsd, uint256 lpUsd) public pure {
        stockUsd = bound(stockUsd, 0, 1e30);
        lpUsd = bound(lpUsd, 0, 1e30);
        (, uint256 bp,,) = SpanMathLib.accountSnapshotUsd(stockUsd, lpUsd, 0, 0);
        uint256 haircut = stockUsd.mulWad(0.85e18) + lpUsd.mulWad(0.70e18);
        assertLe(bp, haircut.mulWad(0.80e18) + 1);
    }

    function testFuzz_feeCreditNeverIncreasesIm(uint256 stockUsd, uint256 fee) public pure {
        stockUsd = bound(stockUsd, 0, 1e30);
        fee = bound(fee, 0, stockUsd);
        (uint256 withoutFee,,,) = SpanMathLib.accountSnapshotUsd(stockUsd, 0, 0, 0);
        (uint256 withFee,,,) = SpanMathLib.accountSnapshotUsd(stockUsd, 0, fee, 0);
        assertLe(withFee, withoutFee);
    }

    function testFuzz_lossesBoundedByLegs(uint256 stockUsd, uint256 lpUsd) public pure {
        stockUsd = bound(stockUsd, 0, 1e30);
        lpUsd = bound(lpUsd, 0, 1e30);
        (,,, uint256[16] memory losses) =
            SpanMathLib.accountSnapshotUsd(stockUsd, lpUsd, 0, 0);
        for (uint256 i = 0; i < 16; i++) {
            assertLe(losses[i], stockUsd + lpUsd);
        }
    }
}
