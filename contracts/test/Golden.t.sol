// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpanMathLib} from "../src/SpanMathLib.sol";

/// @notice Cross-language parity: every generated TS vector must match Solidity byte-for-byte.
/// @dev The golden files flatten each 16-cell grid into static l0..l15 fields so the whole file
///      decodes in one `vm.parseJson` + `abi.decode` pass.
contract GoldenTest is Test {
    struct SpanVector {
        uint256 stockUsd;
        uint256 lpUsd;
        uint256 feeCreditBase;
        uint256 debt;
        uint256 im;
        uint256 bp;
        uint256 health;
        uint256 l0;
        uint256 l1;
        uint256 l2;
        uint256 l3;
        uint256 l4;
        uint256 l5;
        uint256 l6;
        uint256 l7;
        uint256 l8;
        uint256 l9;
        uint256 l10;
        uint256 l11;
        uint256 l12;
        uint256 l13;
        uint256 l14;
        uint256 l15;
    }

    struct SpanFile {
        uint256 count;
        SpanVector[] vectors;
    }

    struct RwaVector {
        uint256 stockUsd;
        uint256 lpUsd;
        uint256 equityRwaUsd;
        uint256 navUsd;
        uint256 feeCreditFees;
        uint256 navAccrualCredit;
        uint256 dailyCoupon;
        uint256 debt;
        bool transferRestricted;
        bool gateOpen;
        uint256 dailyCap;
        uint256 lossR1Base;
        uint256 lossR2;
        uint8 eligR1;
        uint8 eligR2;
        uint256 feeCreditBase;
        uint256 im;
        uint256 bp;
        uint256 health;
        uint256 cStressed;
        uint256 unwindableNow;
        uint256 earningLocked;
        uint256 l0;
        uint256 l1;
        uint256 l2;
        uint256 l3;
        uint256 l4;
        uint256 l5;
        uint256 l6;
        uint256 l7;
        uint256 l8;
        uint256 l9;
        uint256 l10;
        uint256 l11;
        uint256 l12;
        uint256 l13;
        uint256 l14;
        uint256 l15;
    }

    struct RwaFile {
        uint256 count;
        RwaVector[] vectors;
    }

    function test_spanGoldenVectorsMatchSolidity() public view {
        string memory json = vm.readFile("../test-golden/span_golden.json");
        SpanFile memory file = abi.decode(vm.parseJson(json), (SpanFile));

        assertEq(file.count, 1_000, "count");
        assertEq(file.vectors.length, 1_000, "vector length");

        for (uint256 i = 0; i < file.vectors.length; i++) {
            SpanVector memory v = file.vectors[i];
            (uint256 im, uint256 bp, uint256 health, uint256[16] memory losses) =
                SpanMathLib.accountSnapshotUsd(v.stockUsd, v.lpUsd, v.feeCreditBase, v.debt);

            assertEq(im, v.im, "im");
            assertEq(bp, v.bp, "bp");
            assertEq(health, v.health, "health");

            uint256[16] memory expected = [
                v.l0,
                v.l1,
                v.l2,
                v.l3,
                v.l4,
                v.l5,
                v.l6,
                v.l7,
                v.l8,
                v.l9,
                v.l10,
                v.l11,
                v.l12,
                v.l13,
                v.l14,
                v.l15
            ];
            for (uint256 j = 0; j < 16; j++) {
                assertEq(losses[j], expected[j], "scenario loss");
            }
        }
    }

    function test_rwaGoldenVectorsMatchSolidity() public view {
        string memory json = vm.readFile("../test-golden/rwa_golden.json");
        RwaFile memory file = abi.decode(vm.parseJson(json), (RwaFile));

        assertEq(file.count, 300, "count");
        assertEq(file.vectors.length, 300, "vector length");

        for (uint256 i = 0; i < file.vectors.length; i++) {
            RwaVector memory v = file.vectors[i];
            SpanMathLib.PortfolioResult memory r = SpanMathLib.portfolioSnapshotUsd(
                v.stockUsd,
                v.lpUsd,
                v.equityRwaUsd,
                v.navUsd,
                v.feeCreditFees,
                v.navAccrualCredit,
                v.dailyCoupon,
                v.debt,
                v.transferRestricted,
                v.gateOpen,
                v.dailyCap
            );

            assertEq(r.im, v.im, "im");
            assertEq(r.bp, v.bp, "bp");
            assertEq(r.health, v.health, "health");
            assertEq(r.cStressed, v.cStressed, "cStressed");
            assertEq(r.feeCreditBase, v.feeCreditBase, "feeCreditBase");
            assertEq(r.lossR1Base, v.lossR1Base, "lossR1Base");
            assertEq(r.lossR2, v.lossR2, "lossR2");
            assertEq(uint256(r.eligR1), uint256(v.eligR1), "eligR1");
            assertEq(uint256(r.eligR2), uint256(v.eligR2), "eligR2");
            assertEq(r.unwindableNow, v.unwindableNow, "unwindableNow");
            assertEq(r.earningLocked, v.earningLocked, "earningLocked");

            uint256[16] memory expected = [
                v.l0,
                v.l1,
                v.l2,
                v.l3,
                v.l4,
                v.l5,
                v.l6,
                v.l7,
                v.l8,
                v.l9,
                v.l10,
                v.l11,
                v.l12,
                v.l13,
                v.l14,
                v.l15
            ];
            for (uint256 j = 0; j < 16; j++) {
                assertEq(r.scenarioLosses[j], expected[j], "scenario loss");
            }
        }
    }
}
