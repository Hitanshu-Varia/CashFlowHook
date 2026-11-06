// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeMathLib} from "../src/FeeMathLib.sol";

contract FeeMathLibTest is Test {
    function _flat(uint256 daily) internal pure returns (uint256[7] memory fees) {
        for (uint256 i = 0; i < 7; i++) fees[i] = daily;
    }

    function test_average() public pure {
        uint256[7] memory fees = [uint256(1e18), 2e18, 3e18, 4e18, 5e18, 6e18, 7e18];
        assertEq(FeeMathLib.avg7d(fees), 4e18);
    }

    function test_takerFloor() public pure {
        uint256[7] memory fees = _flat(100e18);
        assertEq(FeeMathLib.feeCreditFees(fees, 4), 0);
        assertGt(FeeMathLib.feeCreditFees(fees, 5), 0);
    }

    function test_flatFeeCredit() public pure {
        uint256[7] memory fees = _flat(100e18);
        // 3 * 100, taker factor 10/20 = 0.5, no vol/drawdown penalty
        assertEq(FeeMathLib.feeCreditFees(fees, 10), 150e18);
        // 20+ takers get the full taker factor
        assertEq(FeeMathLib.feeCreditFees(fees, 20), 300e18);
    }

    function test_drawdownPenalty() public pure {
        uint256[7] memory fees = [uint256(100e18), 100e18, 100e18, 50e18, 50e18, 50e18, 50e18];
        uint256 credit = FeeMathLib.feeCreditFees(fees, 20);
        assertLt(credit, 3 * FeeMathLib.avg7d(fees));
    }

    function test_strategyScoreFlat() public pure {
        uint256[7] memory fees = _flat(100e18);
        assertEq(FeeMathLib.strategyScore(fees, 10, 7), 100);
        assertEq(FeeMathLib.strategyScore(fees, 4, 7), 0);
    }

    function test_strategyScoreYoung() public pure {
        uint256[7] memory fees = _flat(100e18);
        // sigma=0, dd=0, age=1/7 -> 0.5 + 0.3 + 0.2*(1/7) = 0.828571... -> 83
        assertEq(FeeMathLib.strategyScore(fees, 10, 1), 83);
    }

    function test_combinedCreditCap() public pure {
        assertEq(FeeMathLib.combinedCredit(100e18, 100e18, 1000e18), 100e18);
        assertEq(FeeMathLib.combinedCredit(100e18, 100e18, 10_000e18), 200e18);
    }

    function testFuzz_creditBoundedByThreeTimesAverage(uint256 a, uint256 b, uint256 takers)
        public
        pure
    {
        a = bound(a, 0, 1e24);
        b = bound(b, 0, 1e24);
        takers = bound(takers, 0, 100);
        uint256[7] memory fees = [a, b, a, b, a, b, a];
        assertLe(FeeMathLib.feeCreditFees(fees, takers), 3 * FeeMathLib.avg7d(fees));
    }

    function testFuzz_scoreWithinRange(uint256 a, uint256 b, uint256 takers, uint256 age) public pure {
        a = bound(a, 0, 1e24);
        b = bound(b, 0, 1e24);
        takers = bound(takers, 0, 100);
        age = bound(age, 0, 3650);
        uint256[7] memory fees = [a, b, a, b, a, b, a];
        uint16 score = FeeMathLib.strategyScore(fees, takers, age);
        assertLe(score, 100);
    }
}
