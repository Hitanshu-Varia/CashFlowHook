// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMarkFeed} from "./interfaces/IMarkFeed.sol";

/// @title MarkFeed
/// @notice Trusted-signer MVP mark feed for the stock leg and the LP position.
/// @dev Production path: TWAP/oracle network; this MVP is disclosed in docs/limits.md.
contract MarkFeed is IMarkFeed {
    struct Mark {
        uint256 markWad;
        uint64 updatedAt;
        bool exists;
    }

    address public owner;
    mapping(address => bool) public writers;
    mapping(bytes32 => Mark) internal _marks;

    event MarkPosted(bytes32 indexed key, uint256 markWad, uint64 updatedAt);
    event WriterSet(address indexed writer, bool allowed);

    error NotAuthorized();
    error NotFound();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyWriter() {
        if (!writers[msg.sender] && msg.sender != owner) revert NotAuthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setWriter(address writer, bool allowed) external onlyOwner {
        writers[writer] = allowed;
        emit WriterSet(writer, allowed);
    }

    function setMark(bytes32 key, uint256 markWad, uint64 updatedAt) external onlyWriter {
        _marks[key] = Mark({markWad: markWad, updatedAt: updatedAt, exists: true});
        emit MarkPosted(key, markWad, updatedAt);
    }

    function getMark(bytes32 key) external view returns (uint256 markWad, uint64 updatedAt) {
        Mark memory m = _marks[key];
        if (!m.exists) revert NotFound();
        return (m.markWad, m.updatedAt);
    }
}
