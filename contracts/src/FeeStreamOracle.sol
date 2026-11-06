// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeeMathLib} from "./FeeMathLib.sol";
import {StrategyBureau} from "./StrategyBureau.sol";

/// @title FeeStreamOracle
/// @notice Trusted-signer MVP for trailing LP fee records with onchain Sybil exclusion.
/// @dev The record is signed by `oracleSigner`, the sample root is recomputed, and any sampled
///      taker equal to the borrower reverts. Production path: decentralized attestation.
contract FeeStreamOracle {
    struct StreamRecord {
        bytes32 strategyPosId;
        uint64 windowStartTs;
        uint256[7] dailyFees;
        uint256 distinctTakers;
        address excludedOwner;
        bytes32 rootHash;
    }

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant STREAM_TYPEHASH = keccak256(
        "StreamRecord(bytes32 strategyPosId,uint64 windowStartTs,uint256[7] dailyFees,uint256 distinctTakers,address excludedOwner,bytes32 rootHash)"
    );
    bytes32 private constant NAME_HASH = keccak256("CashflowHook");
    bytes32 private constant VERSION_HASH = keccak256("1");
    uint256 private constant SECP256K1N_DIV_2 =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    address public owner;
    address public oracleSigner;
    address public bureau;
    mapping(bytes32 => uint64) public lastWindowStart;
    mapping(bytes32 => uint256) public creditFor;
    mapping(bytes32 => StreamRecord) internal _latest;

    event StreamRecorded(bytes32 indexed strategyPosId, uint256 avg, uint256 takers, uint16 score);
    event SignerSet(address indexed signer);
    event BureauSet(address indexed bureau);

    error NotAuthorized();
    error BadSignature();
    error NonMonotonic();
    error RootMismatch();
    error OwnerInSample();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    constructor(address signer, address bureau_) {
        owner = msg.sender;
        oracleSigner = signer;
        bureau = bureau_;
    }

    function setSigner(address signer) external onlyOwner {
        oracleSigner = signer;
        emit SignerSet(signer);
    }

    function setBureau(address bureau_) external onlyOwner {
        bureau = bureau_;
        emit BureauSet(bureau_);
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    function hashRecord(StreamRecord memory r) public view returns (bytes32) {
        bytes32 feesHash = keccak256(
            abi.encodePacked(
                r.dailyFees[0],
                r.dailyFees[1],
                r.dailyFees[2],
                r.dailyFees[3],
                r.dailyFees[4],
                r.dailyFees[5],
                r.dailyFees[6]
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                STREAM_TYPEHASH,
                r.strategyPosId,
                r.windowStartTs,
                feesHash,
                r.distinctTakers,
                r.excludedOwner,
                r.rootHash
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function postRecord(bytes calldata sig, StreamRecord calldata r, bytes32[] calldata sample)
        external
    {
        if (r.windowStartTs <= lastWindowStart[r.strategyPosId]) revert NonMonotonic();

        bytes32 digest = hashRecord(_toMemory(r));
        if (_recover(digest, sig) != oracleSigner) revert BadSignature();

        if (keccak256(abi.encode(sample)) != r.rootHash) revert RootMismatch();

        for (uint256 i = 0; i < sample.length; i++) {
            if (address(uint160(uint256(sample[i]))) == r.excludedOwner) revert OwnerInSample();
        }

        uint256[7] memory fees = _feesToMemory(r);
        uint256 avg = FeeMathLib.avg7d(fees);
        uint256 credit = FeeMathLib.feeCreditFees(fees, r.distinctTakers);
        uint64 ageDays = r.windowStartTs < block.timestamp
            ? uint64((block.timestamp - r.windowStartTs) / 86400)
            : 0;
        uint16 score = FeeMathLib.strategyScore(fees, r.distinctTakers, ageDays);

        lastWindowStart[r.strategyPosId] = r.windowStartTs;
        _latest[r.strategyPosId] = _toMemory(r);
        creditFor[r.strategyPosId] = credit;

        if (bureau != address(0)) {
            StrategyBureau(bureau).postScore(r.strategyPosId, score, r.distinctTakers);
        }

        emit StreamRecorded(r.strategyPosId, avg, r.distinctTakers, score);
    }

    function latestRecord(bytes32 strategyPosId) external view returns (StreamRecord memory) {
        return _latest[strategyPosId];
    }

    function feeCreditFor(bytes32 strategyPosId) external view returns (uint256) {
        return creditFor[strategyPosId];
    }

    function _toMemory(StreamRecord calldata r) internal pure returns (StreamRecord memory m) {
        m.strategyPosId = r.strategyPosId;
        m.windowStartTs = r.windowStartTs;
        m.dailyFees = r.dailyFees;
        m.distinctTakers = r.distinctTakers;
        m.excludedOwner = r.excludedOwner;
        m.rootHash = r.rootHash;
    }

    function _feesToMemory(StreamRecord calldata r) internal pure returns (uint256[7] memory fees) {
        for (uint256 i = 0; i < 7; i++) {
            fees[i] = r.dailyFees[i];
        }
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) revert BadSignature();
        bytes32 rr = bytes32(sig[0:32]);
        bytes32 ss = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        // Reject malleable signatures: high-s and v outside {27,28}.
        if (uint256(ss) > SECP256K1N_DIV_2) revert BadSignature();
        if (v != 27 && v != 28) revert BadSignature();
        address signer = ecrecover(digest, v, rr, ss);
        if (signer == address(0)) revert BadSignature();
        return signer;
    }
}
