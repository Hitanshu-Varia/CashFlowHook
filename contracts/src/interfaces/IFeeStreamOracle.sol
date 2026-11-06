// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IFeeStreamOracle {
    function feeCreditFor(bytes32 strategyPosId) external view returns (uint256);
}
