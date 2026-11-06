// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICreditEngine {
    function stepUp(uint256 accountId, bytes32 proofHash, uint8 newCapTier) external;
    function acceptLockedRisk(uint256 accountId, bytes32 proofHash) external;
    function debtOf(uint256 accountId) external view returns (uint256);
    function ownerOf(uint256 accountId) external view returns (address);
    function draw(uint256 accountId, uint256 amtWad) external;
    function repay(uint256 accountId, uint256 amtWad) external;
}
