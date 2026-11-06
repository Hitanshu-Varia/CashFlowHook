// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAquaAdapter} from "./interfaces/IAquaAdapter.sol";
import {ICreditEngine} from "./interfaces/ICreditEngine.sol";

/// @title AquaCreditLine
/// @notice Thin user-facing line over CreditEngine. Aqua holds a virtual balance; this contract
///         never moves borrower tokens (invariant I1).
contract AquaCreditLine {
    address public owner;
    address public immutable engine;
    address public immutable aqua;

    event LineOpened(uint256 indexed accountId);
    event LineDrawn(uint256 indexed accountId, uint256 amt);
    event LineRepaid(uint256 indexed accountId, uint256 amt);

    error NotAuthorized();

    constructor(address engine_, address aqua_) {
        owner = msg.sender;
        engine = engine_;
        aqua = aqua_;
    }

    function openAccount(uint256 accountId) external {
        if (msg.sender != ICreditEngine(engine).ownerOf(accountId)) revert NotAuthorized();
        emit LineOpened(accountId);
    }

    function draw(uint256 accountId, uint256 amtWad) external {
        if (msg.sender != ICreditEngine(engine).ownerOf(accountId)) revert NotAuthorized();
        ICreditEngine(engine).draw(accountId, amtWad);
        IAquaAdapter(aqua).ship(accountId, amtWad);
        emit LineDrawn(accountId, amtWad);
    }

    function repay(uint256 accountId, uint256 amtWad) external {
        if (msg.sender != ICreditEngine(engine).ownerOf(accountId)) revert NotAuthorized();
        uint256 debt = ICreditEngine(engine).debtOf(accountId);
        uint256 amount = amtWad > debt ? debt : amtWad;
        IAquaAdapter(aqua).dock(accountId, amount);
        ICreditEngine(engine).repay(accountId, amount);
        emit LineRepaid(accountId, amount);
    }

    function creditLineOf(uint256 accountId) external view returns (uint256) {
        return ICreditEngine(engine).debtOf(accountId);
    }

    function aquaBalanceOf(uint256 accountId) external view returns (uint256) {
        return IAquaAdapter(aqua).rawBalances(accountId);
    }
}
