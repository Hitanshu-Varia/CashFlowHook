// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {CreditEngine} from "../src/CreditEngine.sol";
import {RwaCollateralAdapter} from "../src/RwaCollateralAdapter.sol";

contract CreditEngineTest is BaseTest {
    function test_onboardPricing() public view {
        (uint256 bp, uint256 unwindable, uint256 locked, uint256 health) = _breakdown();
        assertEq(bp, 1708.4e18);
        assertEq(unwindable, 3150e18);
        assertEq(locked, 0);
        assertGt(health, 1e18);
        assertEq(uint256(engine.stateOf(ACCOUNT)), uint256(CreditEngine.State.PRICED));
    }

    function test_drawAndRepay() public {
        _draw(100e18);
        assertEq(engine.debtOf(ACCOUNT), 100e18);
        assertEq(uint256(engine.stateOf(ACCOUNT)), uint256(CreditEngine.State.ACTIVE));

        vm.prank(borrower);
        engine.repay(ACCOUNT, 40e18);
        assertEq(engine.debtOf(ACCOUNT), 60e18);

        vm.prank(borrower);
        engine.repay(ACCOUNT, 1000e18);
        assertEq(engine.debtOf(ACCOUNT), 0);
    }

    function test_drawCannotExceedBp() public {
        uint256 bp = engine.computeBp(ACCOUNT);
        vm.expectRevert(CreditEngine.DebtExceedsBp.selector);
        _draw(bp + 1);
    }

    function test_nonOwnerCannotDraw() public {
        vm.prank(agent);
        vm.expectRevert(CreditEngine.NotAuthorized.selector);
        engine.draw(ACCOUNT, 1e18);
    }

    function test_staleStockMarkReverts() public {
        vm.warp(block.timestamp + 1801);
        vm.expectRevert(CreditEngine.STALE_MARK.selector);
        engine.refreshMarks(ACCOUNT);
    }

    function test_gateShutSegregatesTreasury() public {
        engine.setGateState(ACCOUNT, false);
        (uint256 bp, uint256 unwindable, uint256 locked,) = _breakdown();
        assertEq(bp, 1708.4e18);
        assertEq(unwindable, 2300e18);
        assertEq(locked, 850e18);
    }

    function test_transferRestrictionSegregatesEquity() public {
        adapter.setTransferRestricted(equityAsset, true);
        engine.refreshMarks(ACCOUNT);
        (, uint256 unwindable, uint256 locked,) = _breakdown();
        assertEq(unwindable, 2400e18);
        assertEq(locked, 750e18);
    }

    function test_navAccrual() public {
        uint256 before = engine.navAccrualCreditView(ACCOUNT);
        vm.warp(block.timestamp + 1 days + 1);
        engine.accrueCoupon(ACCOUNT);
        uint256 afterCredit = engine.navAccrualCreditView(ACCOUNT);
        assertGt(afterCredit, before);
        assertEq(afterCredit - before, 86.4e18 + 1e15);
    }

    function test_couponNotMatureReverts() public {
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(CreditEngine.CouponNotMature.selector);
        engine.accrueCoupon(ACCOUNT);
    }

    function test_staleNavReverts() public {
        vm.warp(block.timestamp + 93601);
        vm.expectRevert(CreditEngine.NavStale.selector);
        engine.accrueCoupon(ACCOUNT);
    }

    function test_feeCreditIsCapped() public {
        _postFeeRecord(100_000e18);
        engine.refreshMarks(ACCOUNT);
        uint256 credit = engine.feeCreditBaseOf(ACCOUNT);
        assertEq(credit, 400e18); // 10% of $4,000 gross collateral
    }

    function test_agentDrawCaps() public {
        uint256 bp = engine.computeBp(ACCOUNT);
        uint256 perDraw = (bp * 2) / 100;

        vm.prank(agent);
        engine.agentDraw(ACCOUNT, perDraw);
        vm.prank(agent);
        engine.agentDraw(ACCOUNT, perDraw);
        vm.prank(agent);
        engine.agentDraw(ACCOUNT, perDraw);

        vm.prank(agent);
        vm.expectRevert(CreditEngine.CapExceededBlock.selector);
        engine.agentDraw(ACCOUNT, perDraw);
    }

    function test_agentDrawAbovePerDrawCapReverts() public {
        uint256 bp = engine.computeBp(ACCOUNT);
        uint256 perDraw = (bp * 2) / 100;
        vm.prank(agent);
        vm.expectRevert(CreditEngine.CapExceededBlock.selector);
        engine.agentDraw(ACCOUNT, perDraw + 1);
    }

    function test_stepUpRaisesCap() public {
        bytes32 proof = keccak256("step-up-1");
        verifier.acceptProof(borrower, ACCOUNT, proof, 1, uint64(block.timestamp + 1 hours));
        CreditEngine.Account memory a = engine.getAccount(ACCOUNT);
        assertEq(a.aut.capBps, 500);
        assertEq(a.aut.expiresAt, uint64(block.timestamp + 24 hours));

        vm.expectRevert(bytes4(keccak256("ReplayedProof()")));
        verifier.acceptProof(borrower, ACCOUNT, proof, 1, uint64(block.timestamp + 1 hours));
    }

    function test_onlyVerifierCanStepUp() public {
        vm.expectRevert(CreditEngine.NotAuthorized.selector);
        engine.stepUp(ACCOUNT, keccak256("x"), 1);
    }

    function test_acceptLockedRisk() public {
        bytes32 proof = keccak256("locked-risk-1");
        verifier.acceptLockedRisk(borrower, ACCOUNT, proof, uint64(block.timestamp + 1 hours));
        CreditEngine.Account memory a = engine.getAccount(ACCOUNT);
        assertTrue(a.lockedRiskAccepted);
        assertEq(a.lockedRiskExpiry, uint64(block.timestamp + 24 hours));
    }

    function _makeLockedBook() internal {
        adapter.setTransferRestricted(equityAsset, true);
        engine.refreshMarks(ACCOUNT);
        engine.setGateState(ACCOUNT, false);
        (, uint256 unwindable,,) = _breakdown();
        assertEq(unwindable, 1550e18);
    }

    function test_unwindAtomicZeroBadDebt() public {
        _makeLockedBook();
        _draw(1300e18);
        liquidity.setProceeds(1300e18);

        vm.expectEmit(true, false, false, true, address(engine));
        emit CreditEngine.Unwound(ACCOUNT, 1300e18, 0);
        engine.unwind(ACCOUNT);

        assertEq(engine.debtOf(ACCOUNT), 0);
        assertEq(uint256(engine.stateOf(ACCOUNT)), uint256(CreditEngine.State.PRICED));
    }

    function test_unwindBeyondUnwindableReverts() public {
        _makeLockedBook();
        _draw(1600e18);
        liquidity.setProceeds(1600e18);

        vm.expectRevert(CreditEngine.InsufficientUnwindable.selector);
        engine.unwind(ACCOUNT);
    }

    function test_lockedRiskStepUpAllowsUnwind() public {
        _makeLockedBook();
        _draw(1600e18);
        verifier.acceptLockedRisk(
            borrower, ACCOUNT, keccak256("locked-risk-2"), uint64(block.timestamp + 1 hours)
        );
        liquidity.setProceeds(1600e18);
        engine.unwind(ACCOUNT);
        assertEq(engine.debtOf(ACCOUNT), 0);
    }

    function test_badDebtProjectionReverts() public {
        _makeLockedBook();
        _draw(1300e18);
        liquidity.setProceeds(1299e18);

        vm.expectRevert(CreditEngine.BadDebtProjection.selector);
        engine.unwind(ACCOUNT);
    }

    function test_healthyAccountCannotBeUnwound() public {
        _draw(100e18);
        liquidity.setProceeds(100e18);
        vm.expectRevert(CreditEngine.UnwindNotEligible.selector);
        engine.unwind(ACCOUNT);
    }

    function test_unwindFallbackPath() public {
        _makeLockedBook();
        _draw(1300e18);
        engine.unwindNettedFallback(ACCOUNT, 1300e18);
        assertEq(engine.debtOf(ACCOUNT), 0);
    }

    function test_markDropMovesAccountToStressed() public {
        _draw(1700e18);
        // Drop marks: stock $200, LP $200 -> stressed equity collapses below maintenance.
        markFeed.setMark(bytes32(uint256(uint160(stockToken))), 20e18, uint64(block.timestamp));
        markFeed.setMark(bytes32(lpTokenId), 10e18, uint64(block.timestamp));
        engine.refreshMarks(ACCOUNT);
        assertEq(uint256(engine.stateOf(ACCOUNT)), uint256(CreditEngine.State.STRESSED));
    }

    function test_rwaPositionOnlyOwner() public {
        vm.prank(agent);
        vm.expectRevert(CreditEngine.NotAuthorized.selector);
        engine.setRwaPosition(ACCOUNT, equityAsset, 1e18);
    }

    function test_debtNeverExceedsBpOnDrawFuzz(uint256 amount) public {
        uint256 bp = engine.computeBp(ACCOUNT);
        amount = bound(amount, 1, bp);
        _draw(amount);
        assertLe(engine.debtOf(ACCOUNT), engine.computeBp(ACCOUNT));
    }
}
