// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Adapter boundary for 1inch Aqua. External names are assumptions until verified
///         against the 1inch/aqua deployment; a wrong guess breaks only this interface's impl.
interface IAquaAdapter {
    function ship(uint256 accountId, uint256 amountWad) external;
    function dock(uint256 accountId, uint256 amountWad) external;
    function pull(uint256 accountId, uint256 amountWad) external;
    function push(uint256 accountId, uint256 amountWad) external;
    function rawBalances(uint256 accountId) external view returns (uint256);
}
