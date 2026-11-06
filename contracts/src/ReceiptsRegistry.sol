// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ReceiptsRegistry
/// @notice Append-only agent spend receipts. Every agent spend is visible to the account owner.
contract ReceiptsRegistry {
    struct Receipt {
        address account;
        address to;
        uint256 amount;
        bytes32 memo;
        uint64 ts;
    }

    mapping(address => mapping(address => bool)) public agents;
    mapping(address => Receipt[]) internal _receipts;

    event AgentSet(address indexed account, address indexed agent, bool allowed);
    event AgentSpent(
        address indexed account, address indexed to, uint256 amount, bytes32 memo, uint64 ts
    );

    error NotAuthorized();

    function setAgent(address agent, bool allowed) external {
        agents[msg.sender][agent] = allowed;
        emit AgentSet(msg.sender, agent, allowed);
    }

    function record(address account, address to, uint256 amount, bytes32 memo) public {
        if (msg.sender != account && !agents[account][msg.sender]) revert NotAuthorized();
        _receipts[account].push(
            Receipt({account: account, to: to, amount: amount, memo: memo, ts: uint64(block.timestamp)})
        );
        emit AgentSpent(account, to, amount, memo, uint64(block.timestamp));
    }

    /// @notice Mirror for an x402 settlement observed by the agent.
    function spendObserved(address account, address to, uint256 amount, bytes32 memo) external {
        record(account, to, amount, memo);
    }

    function receiptCount(address account) external view returns (uint256) {
        return _receipts[account].length;
    }

    function receiptAt(address account, uint256 i) external view returns (Receipt memory) {
        return _receipts[account][i];
    }
}
