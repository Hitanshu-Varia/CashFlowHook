// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IMarkFeed {
    function getMark(bytes32 key) external view returns (uint256 markWad, uint64 updatedAt);
}
