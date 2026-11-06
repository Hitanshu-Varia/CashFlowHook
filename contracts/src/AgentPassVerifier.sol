// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICreditEngine} from "./interfaces/ICreditEngine.sol";

/// @title AgentPassVerifier
/// @notice Onchain allow-list for a World Agent Pass proof that was already validated
///         server-side. A client-asserted result is never authorization.
/// @dev The backend key calls acceptProof/acceptLockedRisk. Proof hashes are single-use.
contract AgentPassVerifier {
    struct Proof {
        address account;
        uint8 capTier;
        uint64 expiry;
        uint64 ts;
        bool lockedRisk;
    }

    address public owner;
    address public backend;
    address public engine;
    mapping(bytes32 => bool) public used;
    mapping(address => Proof[]) internal _history;

    event ProofAccepted(address indexed account, bytes32 indexed proofHash, uint8 capTier, uint64 expiry);
    event LockedRiskProofAccepted(address indexed account, bytes32 indexed proofHash, uint64 expiry);
    event BackendSet(address indexed backend);

    error NotAuthorized();
    error ReplayedProof();
    error ExpiredProof();

    modifier onlyBackend() {
        if (msg.sender != backend) revert NotAuthorized();
        _;
    }

    constructor(address backend_, address engine_) {
        owner = msg.sender;
        backend = backend_;
        engine = engine_;
    }

    function setBackend(address backend_) external {
        if (msg.sender != owner) revert NotAuthorized();
        backend = backend_;
        emit BackendSet(backend_);
    }

    function setEngine(address engine_) external {
        if (msg.sender != owner) revert NotAuthorized();
        engine = engine_;
    }

    function acceptProof(
        address account,
        uint256 accountId,
        bytes32 proofHash,
        uint8 capTier,
        uint64 expiry
    ) external onlyBackend {
        if (proofHash == bytes32(0)) revert NotAuthorized();
        if (used[proofHash]) revert ReplayedProof();
        if (expiry <= block.timestamp) revert ExpiredProof();
        used[proofHash] = true;
        _history[account].push(
            Proof({
                account: account,
                capTier: capTier,
                expiry: expiry,
                ts: uint64(block.timestamp),
                lockedRisk: false
            })
        );
        ICreditEngine(engine).stepUp(accountId, proofHash, capTier);
        emit ProofAccepted(account, proofHash, capTier, expiry);
    }

    function acceptLockedRisk(
        address account,
        uint256 accountId,
        bytes32 proofHash,
        uint64 expiry
    ) external onlyBackend {
        if (proofHash == bytes32(0)) revert NotAuthorized();
        if (used[proofHash]) revert ReplayedProof();
        if (expiry <= block.timestamp) revert ExpiredProof();
        used[proofHash] = true;
        _history[account].push(
            Proof({
                account: account,
                capTier: 0,
                expiry: expiry,
                ts: uint64(block.timestamp),
                lockedRisk: true
            })
        );
        ICreditEngine(engine).acceptLockedRisk(accountId, proofHash);
        emit LockedRiskProofAccepted(account, proofHash, expiry);
    }

    function proofCount(address account) external view returns (uint256) {
        return _history[account].length;
    }

    function proofAt(address account, uint256 i) external view returns (Proof memory) {
        return _history[account][i];
    }
}
