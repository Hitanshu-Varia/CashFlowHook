// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAquaAdapter} from "../interfaces/IAquaAdapter.sol";

/// @notice Local Aqua adapter used by unit/invariant tests and the offline demo.
/// @dev Virtual balances only: no ERC-20 custody, matching invariant I1.
contract MockAqua is IAquaAdapter {
    mapping(uint256 => uint256) internal _balances;

    error InsufficientVirtualBalance();

    function ship(uint256 accountId, uint256 amountWad) external {
        _balances[accountId] += amountWad;
    }

    function dock(uint256 accountId, uint256 amountWad) external {
        if (_balances[accountId] < amountWad) revert InsufficientVirtualBalance();
        _balances[accountId] -= amountWad;
    }

    function pull(uint256 accountId, uint256 amountWad) external {
        _balances[accountId] += amountWad;
    }

    function push(uint256 accountId, uint256 amountWad) external {
        if (_balances[accountId] < amountWad) revert InsufficientVirtualBalance();
        _balances[accountId] -= amountWad;
    }

    function rawBalances(uint256 accountId) external view returns (uint256) {
        return _balances[accountId];
    }
}
