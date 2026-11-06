// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StrategyBureau} from "../src/StrategyBureau.sol";

contract StrategyBureauTest is Test {
    StrategyBureau internal bureau;
    bytes32 internal constant ID = keccak256("strategy-one");
    address internal oracle = address(0x0A11CE);

    function setUp() public {
        bureau = new StrategyBureau(oracle);
    }

    function test_anyoneCanRegister() public {
        vm.prank(address(0xA11CE));
        bureau.register(ID);
        assertTrue(bureau.registered(ID));
    }

    function test_registerIsIdempotent() public {
        bureau.register(ID);
        bureau.register(ID);
        assertTrue(bureau.registered(ID));
    }

    function test_registerZeroReverts() public {
        vm.expectRevert(StrategyBureau.UnknownStrategy.selector);
        bureau.register(bytes32(0));
    }

    function test_onlyOracleCanPostScore() public {
        vm.expectRevert(StrategyBureau.NotAuthorized.selector);
        bureau.postScore(ID, 80, 10);
    }

    function test_postScoreAutoRegisters() public {
        vm.prank(oracle);
        bureau.postScore(ID, 80, 10);
        assertTrue(bureau.registered(ID));
        (uint16 score, uint64 ts) = bureau.latestScore(ID);
        assertEq(score, 80);
        assertEq(ts, uint64(block.timestamp));
    }

    function test_appendOnlyStrictTimestamps() public {
        vm.prank(oracle);
        bureau.postScore(ID, 50, 10);
        vm.warp(block.timestamp + 1);
        vm.prank(oracle);
        bureau.postScore(ID, 70, 12);

        assertEq(bureau.recordCount(ID), 2);
        StrategyBureau.ScoreRecord memory first = bureau.recordAt(ID, 0);
        StrategyBureau.ScoreRecord memory second = bureau.recordAt(ID, 1);
        assertLt(first.ts, second.ts);
        assertEq(first.score, 50);
        assertEq(second.score, 70);
    }

    function test_sameTimestampReverts() public {
        vm.prank(oracle);
        bureau.postScore(ID, 50, 10);
        vm.expectRevert(StrategyBureau.NonMonotonic.selector);
        vm.prank(oracle);
        bureau.postScore(ID, 60, 10);
    }

    function test_earlierTimestampReverts() public {
        vm.warp(1_800_000_100);
        vm.prank(oracle);
        bureau.postScore(ID, 50, 10);

        vm.warp(1_800_000_050);
        vm.expectRevert(StrategyBureau.NonMonotonic.selector);
        vm.prank(oracle);
        bureau.postScore(ID, 60, 10);
    }

    function test_scoreClampedTo100() public {
        vm.prank(oracle);
        bureau.postScore(ID, 101, 10);
        (uint16 score,) = bureau.latestScore(ID);
        assertEq(score, 100);
    }

    function test_unknownStrategyLatestIsZero() public view {
        (uint16 score, uint64 ts) = bureau.latestScore(keccak256("missing"));
        assertEq(score, 0);
        assertEq(ts, 0);
    }

    function test_setOracleOnlyOwner() public {
        vm.prank(address(0xA11CE));
        vm.expectRevert(StrategyBureau.NotAuthorized.selector);
        bureau.setOracle(address(0xBEEF));
    }

    function test_rotatedOracleCanPost() public {
        bureau.setOracle(address(0xBEEF));
        vm.prank(address(0xBEEF));
        bureau.postScore(ID, 42, 5);
        (uint16 score,) = bureau.latestScore(ID);
        assertEq(score, 42);
    }

    function testFuzz_scoreAlwaysClamped(uint16 score) public {
        vm.prank(oracle);
        bureau.postScore(ID, score, 10);
        (uint16 stored,) = bureau.latestScore(ID);
        assertLe(stored, 100);
    }
}
