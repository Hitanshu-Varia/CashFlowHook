// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title StrategyBureau
/// @notice Append-only strategy score registry. Anyone may register a strategy; only the
///         oracle may post a score. A score is derived data, not a stored ranking.
contract StrategyBureau {
    struct ScoreRecord {
        uint16 score;
        uint256 takers;
        uint64 ts;
    }

    address public owner;
    address public oracle;
    mapping(bytes32 => bool) public registered;
    mapping(bytes32 => ScoreRecord[]) internal _records;

    event Registered(bytes32 indexed strategyId, address indexed by);
    event ScorePosted(bytes32 indexed strategyId, uint16 score, uint256 takers, uint64 ts);
    event OracleSet(address indexed oracle);

    error NotAuthorized();
    error NonMonotonic();
    error UnknownStrategy();

    modifier onlyOracle() {
        if (msg.sender != oracle) revert NotAuthorized();
        _;
    }

    constructor(address oracle_) {
        owner = msg.sender;
        oracle = oracle_;
    }

    function setOracle(address oracle_) external {
        if (msg.sender != owner) revert NotAuthorized();
        oracle = oracle_;
        emit OracleSet(oracle_);
    }

    function register(bytes32 strategyId) external {
        if (strategyId == bytes32(0)) revert UnknownStrategy();
        if (!registered[strategyId]) {
            registered[strategyId] = true;
            emit Registered(strategyId, msg.sender);
        }
    }

    function postScore(bytes32 strategyId, uint16 score, uint256 takers) external onlyOracle {
        if (!registered[strategyId]) {
            registered[strategyId] = true;
            emit Registered(strategyId, msg.sender);
        }
        ScoreRecord[] storage list = _records[strategyId];
        if (list.length > 0 && block.timestamp <= list[list.length - 1].ts) {
            revert NonMonotonic();
        }
        if (score > 100) score = 100;
        list.push(ScoreRecord({score: score, takers: takers, ts: uint64(block.timestamp)}));
        emit ScorePosted(strategyId, score, takers, uint64(block.timestamp));
    }

    function recordCount(bytes32 strategyId) external view returns (uint256) {
        return _records[strategyId].length;
    }

    function recordAt(bytes32 strategyId, uint256 i) external view returns (ScoreRecord memory) {
        return _records[strategyId][i];
    }

    function latestScore(bytes32 strategyId) external view returns (uint16 score, uint64 ts) {
        ScoreRecord[] storage list = _records[strategyId];
        if (list.length == 0) return (0, 0);
        ScoreRecord storage last = list[list.length - 1];
        return (last.score, last.ts);
    }
}
