// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {AgentPassVerifier} from "../src/AgentPassVerifier.sol";
import {CreditEngine} from "../src/CreditEngine.sol";

contract AgentPassVerifierTest is BaseTest {
    bytes32 internal constant PROOF = keccak256("agent-pass-proof-1");
    uint64 internal expiry;

    function setUp() public override {
        super.setUp();
        expiry = uint64(block.timestamp + 1 hours);
    }

    function test_backendAcceptsProofAndEngineStepsUp() public {
        verifier.acceptProof(borrower, ACCOUNT, PROOF, 2, expiry);

        CreditEngine.Account memory a = engine.getAccount(ACCOUNT);
        assertEq(a.aut.capBps, 1000);
        assertEq(a.aut.expiresAt, uint64(block.timestamp + 24 hours));
        assertEq(a.aut.needsStepUp, false);

        assertEq(verifier.proofCount(borrower), 1);
        AgentPassVerifier.Proof memory p = verifier.proofAt(borrower, 0);
        assertEq(p.account, borrower);
        assertEq(p.capTier, 2);
        assertEq(p.expiry, expiry);
        assertEq(p.ts, uint64(block.timestamp));
        assertEq(p.lockedRisk, false);
    }

    function test_capTierMapping() public {
        verifier.acceptProof(borrower, ACCOUNT, keccak256("tier-0"), 0, expiry);
        assertEq(engine.getAccount(ACCOUNT).aut.capBps, 200);

        verifier.acceptProof(borrower, ACCOUNT, keccak256("tier-1"), 1, expiry);
        assertEq(engine.getAccount(ACCOUNT).aut.capBps, 500);

        verifier.acceptProof(borrower, ACCOUNT, keccak256("tier-2"), 2, expiry);
        assertEq(engine.getAccount(ACCOUNT).aut.capBps, 1000);
    }

    function test_replayReverts() public {
        verifier.acceptProof(borrower, ACCOUNT, PROOF, 1, expiry);

        vm.expectRevert(AgentPassVerifier.ReplayedProof.selector);
        verifier.acceptProof(borrower, ACCOUNT, PROOF, 1, expiry);
    }

    function test_replayAcrossAccountsReverts() public {
        verifier.acceptProof(borrower, ACCOUNT, PROOF, 1, expiry);

        vm.expectRevert(AgentPassVerifier.ReplayedProof.selector);
        verifier.acceptProof(address(0xA11CE), ACCOUNT, PROOF, 1, expiry);
    }

    function test_expiredProofReverts() public {
        vm.expectRevert(AgentPassVerifier.ExpiredProof.selector);
        verifier.acceptProof(borrower, ACCOUNT, PROOF, 1, uint64(block.timestamp));
    }

    function test_futureExpiryRequired() public {
        vm.warp(expiry + 1);
        vm.expectRevert(AgentPassVerifier.ExpiredProof.selector);
        verifier.acceptProof(borrower, ACCOUNT, PROOF, 1, expiry);
    }

    function test_zeroProofHashReverts() public {
        vm.expectRevert(AgentPassVerifier.NotAuthorized.selector);
        verifier.acceptProof(borrower, ACCOUNT, bytes32(0), 1, expiry);
    }

    function test_onlyBackendCanAcceptProof() public {
        vm.prank(borrower);
        vm.expectRevert(AgentPassVerifier.NotAuthorized.selector);
        verifier.acceptProof(borrower, ACCOUNT, PROOF, 1, expiry);
    }

    function test_lockedRiskAcceptedAndRecorded() public {
        verifier.acceptLockedRisk(borrower, ACCOUNT, PROOF, expiry);

        CreditEngine.Account memory a = engine.getAccount(ACCOUNT);
        assertTrue(a.lockedRiskAccepted);
        assertEq(a.lockedRiskExpiry, uint64(block.timestamp + 24 hours));
        assertEq(verifier.proofCount(borrower), 1);

        AgentPassVerifier.Proof memory p = verifier.proofAt(borrower, 0);
        assertTrue(p.lockedRisk);
        assertEq(p.capTier, 0);
    }

    function test_lockedRiskReplayReverts() public {
        verifier.acceptLockedRisk(borrower, ACCOUNT, PROOF, expiry);
        vm.expectRevert(AgentPassVerifier.ReplayedProof.selector);
        verifier.acceptLockedRisk(borrower, ACCOUNT, PROOF, expiry);
    }

    function test_lockedRiskExpiredReverts() public {
        vm.expectRevert(AgentPassVerifier.ExpiredProof.selector);
        verifier.acceptLockedRisk(borrower, ACCOUNT, PROOF, uint64(block.timestamp));
    }

    function test_setBackendOnlyOwner() public {
        vm.prank(borrower);
        vm.expectRevert(AgentPassVerifier.NotAuthorized.selector);
        verifier.setBackend(address(0xBEEF));
    }

    function test_setEngineOnlyOwner() public {
        vm.prank(borrower);
        vm.expectRevert(AgentPassVerifier.NotAuthorized.selector);
        verifier.setEngine(address(0xBEEF));
    }

    function test_directEngineStepUpReverts() public {
        vm.expectRevert(CreditEngine.NotAuthorized.selector);
        engine.stepUp(ACCOUNT, PROOF, 1);
    }

    function test_directLockedRiskReverts() public {
        vm.expectRevert(CreditEngine.NotAuthorized.selector);
        engine.acceptLockedRisk(ACCOUNT, PROOF);
    }

    function test_proofHistoryIsAppendOnly() public {
        verifier.acceptProof(borrower, ACCOUNT, keccak256("p1"), 1, expiry);
        verifier.acceptProof(borrower, ACCOUNT, keccak256("p2"), 2, expiry);
        assertEq(verifier.proofCount(borrower), 2);

        AgentPassVerifier.Proof memory first = verifier.proofAt(borrower, 0);
        AgentPassVerifier.Proof memory second = verifier.proofAt(borrower, 1);
        assertEq(first.capTier, 1);
        assertEq(second.capTier, 2);
    }
}
