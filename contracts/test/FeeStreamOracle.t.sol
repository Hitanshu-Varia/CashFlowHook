// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {FeeStreamOracle} from "../src/FeeStreamOracle.sol";
import {StrategyBureau} from "../src/StrategyBureau.sol";

contract FeeStreamOracleTest is BaseTest {
    function _record(
        uint64 windowStart,
        uint256 daily,
        uint256 takers,
        address excludedOwner,
        bytes32[] memory sample
    ) internal view returns (FeeStreamOracle.StreamRecord memory r) {
        r = FeeStreamOracle.StreamRecord({
            strategyPosId: bytes32(lpTokenId),
            windowStartTs: windowStart,
            dailyFees: [daily, daily, daily, daily, daily, daily, daily],
            distinctTakers: takers,
            excludedOwner: excludedOwner,
            rootHash: keccak256(abi.encode(sample))
        });
    }

    function test_postRecordVerifiesSignatureAndStoresCredit() public {
        bytes32[] memory sample = _sample();
        FeeStreamOracle.StreamRecord memory r =
            _record(uint64(block.timestamp - 7 days), 100e18, 20, borrower, sample);

        feeOracle.postRecord(_sign(FEE_PK, feeOracle.hashRecord(r)), r, sample);

        assertEq(feeOracle.feeCreditFor(bytes32(lpTokenId)), 300e18);
        FeeStreamOracle.StreamRecord memory stored = feeOracle.latestRecord(bytes32(lpTokenId));
        assertEq(stored.strategyPosId, bytes32(lpTokenId));
        assertEq(stored.distinctTakers, 20);
        assertEq(stored.rootHash, r.rootHash);

        (uint16 score, uint64 ts) = bureau.latestScore(bytes32(lpTokenId));
        assertEq(score, 100);
        assertEq(ts, uint64(block.timestamp));
    }

    function test_badSignatureReverts() public {
        bytes32[] memory sample = _sample();
        FeeStreamOracle.StreamRecord memory r =
            _record(uint64(block.timestamp - 7 days), 100e18, 20, borrower, sample);

        bytes memory badSig = _sign(FEE_PK + 1, feeOracle.hashRecord(r));
        vm.expectRevert(FeeStreamOracle.BadSignature.selector);
        feeOracle.postRecord(badSig, r, sample);
    }

    function test_highSSignatureReverts() public {
        bytes32[] memory sample = _sample();
        FeeStreamOracle.StreamRecord memory r =
            _record(uint64(block.timestamp - 7 days), 100e18, 20, borrower, sample);

        (uint8 v, bytes32 sigR, bytes32 sigS) = vm.sign(FEE_PK, feeOracle.hashRecord(r));
        // Flip s into the malformed high-s range while keeping a 65-byte layout.
        sigS = bytes32(uint256(sigS) | (1 << 255));
        bytes memory highS = abi.encodePacked(sigR, sigS, v);

        vm.expectRevert(FeeStreamOracle.BadSignature.selector);
        feeOracle.postRecord(highS, r, sample);
    }

    function test_nonMonotonicWindowReverts() public {
        bytes32[] memory sample = _sample();
        uint64 first = uint64(block.timestamp - 7 days);
        FeeStreamOracle.StreamRecord memory r1 =
            _record(first, 100e18, 20, borrower, sample);
        feeOracle.postRecord(_sign(FEE_PK, feeOracle.hashRecord(r1)), r1, sample);

        FeeStreamOracle.StreamRecord memory r2 =
            _record(first, 200e18, 20, borrower, sample);
        bytes memory sig2 = _sign(FEE_PK, feeOracle.hashRecord(r2));
        vm.expectRevert(FeeStreamOracle.NonMonotonic.selector);
        feeOracle.postRecord(sig2, r2, sample);
    }

    function test_rootMismatchReverts() public {
        bytes32[] memory sample = _sample();
        FeeStreamOracle.StreamRecord memory r =
            _record(uint64(block.timestamp - 7 days), 100e18, 20, borrower, sample);
        bytes32[] memory otherSample = new bytes32[](1);
        otherSample[0] = bytes32(uint256(0xDEAD));

        bytes memory sig = _sign(FEE_PK, feeOracle.hashRecord(r));
        vm.expectRevert(FeeStreamOracle.RootMismatch.selector);
        feeOracle.postRecord(sig, r, otherSample);
    }

    function test_ownerInSampleReverts() public {
        bytes32[] memory sample = _sample();
        sample[2] = bytes32(uint256(uint160(borrower)));
        FeeStreamOracle.StreamRecord memory r =
            _record(uint64(block.timestamp - 7 days), 100e18, 20, borrower, sample);

        bytes memory sig = _sign(FEE_PK, feeOracle.hashRecord(r));
        vm.expectRevert(FeeStreamOracle.OwnerInSample.selector);
        feeOracle.postRecord(sig, r, sample);
    }

    function test_takerFloorGivesZeroCredit() public {
        bytes32[] memory sample = _sample();
        FeeStreamOracle.StreamRecord memory r =
            _record(uint64(block.timestamp - 7 days), 100e18, 4, borrower, sample);

        feeOracle.postRecord(_sign(FEE_PK, feeOracle.hashRecord(r)), r, sample);

        assertEq(feeOracle.feeCreditFor(bytes32(lpTokenId)), 0);
        (uint16 score,) = bureau.latestScore(bytes32(lpTokenId));
        assertEq(score, 0);
    }

    function test_takerFloorBoundary() public {
        bytes32[] memory sample = _sample();
        FeeStreamOracle.StreamRecord memory r =
            _record(uint64(block.timestamp - 7 days), 100e18, 5, borrower, sample);

        feeOracle.postRecord(_sign(FEE_PK, feeOracle.hashRecord(r)), r, sample);

        // 3 * 100 * (5/20) = 75
        assertEq(feeOracle.feeCreditFor(bytes32(lpTokenId)), 75e18);
    }

    function test_volatilityAndDrawdownReduceCredit() public {
        bytes32[] memory sample = _sample();
        FeeStreamOracle.StreamRecord memory r = FeeStreamOracle.StreamRecord({
            strategyPosId: bytes32(lpTokenId),
            windowStartTs: uint64(block.timestamp - 7 days),
            dailyFees: [uint256(100e18), 100e18, 100e18, 50e18, 50e18, 50e18, 50e18],
            distinctTakers: 20,
            excludedOwner: borrower,
            rootHash: keccak256(abi.encode(sample))
        });

        feeOracle.postRecord(_sign(FEE_PK, feeOracle.hashRecord(r)), r, sample);

        uint256 credit = feeOracle.feeCreditFor(bytes32(lpTokenId));
        uint256 prePenalty = uint256(1500e18) / 7;
        assertGt(credit, 0);
        assertLt(credit, prePenalty);
    }

    function test_onlyOwnerCanRotateSigner() public {
        vm.prank(borrower);
        vm.expectRevert(FeeStreamOracle.NotAuthorized.selector);
        feeOracle.setSigner(address(0xBEEF));
    }

    function test_onlyOwnerCanRotateBureau() public {
        vm.prank(borrower);
        vm.expectRevert(FeeStreamOracle.NotAuthorized.selector);
        feeOracle.setBureau(address(0xBEEF));
    }

    function test_rotatedSignerIsRequired() public {
        vm.prank(address(this));
        feeOracle.setSigner(address(0xBEEF));

        bytes32[] memory sample = _sample();
        FeeStreamOracle.StreamRecord memory r =
            _record(uint64(block.timestamp - 7 days), 100e18, 20, borrower, sample);

        bytes memory sig = _sign(FEE_PK, feeOracle.hashRecord(r));
        vm.expectRevert(FeeStreamOracle.BadSignature.selector);
        feeOracle.postRecord(sig, r, sample);
    }

    function test_scoreAppearsInBureau() public {
        _postFeeRecord(100e18);
        bytes32 id = bytes32(lpTokenId);
        (uint16 score, uint64 ts) = bureau.latestScore(id);
        assertEq(score, 100);
        assertEq(ts, uint64(block.timestamp));
        assertEq(bureau.recordCount(id), 1);
    }
}
