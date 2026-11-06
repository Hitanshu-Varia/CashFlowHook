// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUnwindLiquidity} from "../SpanVMRouter.sol";

/// @notice Deterministic local liquidity leg for unit tests. The production router would burn
///         the v4 LP, sell stock/R1 into USDC through the Aqua path, and return proceeds.
contract MockLiquidity is IUnwindLiquidity {
    uint256 public proceeds;
    mapping(uint256 => uint256) public proceedsFor;

    function setProceeds(uint256 amount) external {
        proceeds = amount;
    }

    function setProceedsFor(uint256 accountId, uint256 amount) external {
        proceedsFor[accountId] = amount;
    }

    function liquidate(uint256 accountId) external returns (uint256) {
        uint256 amount = proceedsFor[accountId] == 0 ? proceeds : proceedsFor[accountId];
        proceedsFor[accountId] = 0;
        return amount;
    }
}
