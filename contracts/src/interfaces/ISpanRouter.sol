// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ISpanRouter {
    function spanNetUnwind(uint256 accountId) external returns (uint256 usdcReceived);
}
