// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPortfolioMarginHook {
    function lockPosition(uint256 tokenId, uint256 accountId) external;
    function unlockPosition(uint256 tokenId) external;
}
