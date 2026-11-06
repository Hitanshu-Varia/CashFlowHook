// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IUnwindLiquidity {
    function liquidate(uint256 accountId) external returns (uint256 usdcReceived);
}

/// @title SpanVMRouter
/// @notice Instruction surface for `0xf1 spanNetUnwind`. The opcode path is adapter-isolated:
///         if the vendored SwapVM patch gate fails, CreditEngine.unwindNettedFallback drives the
///         identical six steps in plain EVM.
/// @dev The instruction layout is 0xf1 | 1 byte accountIdx | 4 bytes maxGasHint (little-endian).
contract SpanVMRouter {
    uint8 public constant SPAN_NET_UNWIND = 0xf1;

    address public owner;
    address public immutable engine;
    address public immutable liquidity;

    event SpanNetUnwind(uint256 indexed accountId, uint256 usdcReceived, uint256 gasUsed);
    event Executed(bytes data, uint256 accountId);

    error NotAuthorized();
    error UnknownInstruction();
    error EmptyAccount();

    constructor(address engine_, address liquidity_) {
        owner = msg.sender;
        engine = engine_;
        liquidity = liquidity_;
    }

    function spanNetUnwind(uint256 accountId) external returns (uint256 usdcReceived) {
        if (msg.sender != engine) revert NotAuthorized();
        usdcReceived = IUnwindLiquidity(liquidity).liquidate(accountId);
        emit SpanNetUnwind(accountId, usdcReceived, gasleft());
    }

    /// @notice Minimal instruction dispatcher for the patched SwapVM surface.
    function exec(bytes calldata data) external returns (uint256 usdcReceived) {
        if (msg.sender != engine) revert NotAuthorized();
        if (data.length < 6) revert UnknownInstruction();
        if (uint8(data[0]) != SPAN_NET_UNWIND) revert UnknownInstruction();

        uint256 accountId = uint8(data[1]);
        if (accountId == 0) revert EmptyAccount();

        // bytes 2..5 are the maxGasHint; kept for forward compatibility with the SwapVM patch.
        usdcReceived = IUnwindLiquidity(liquidity).liquidate(accountId);
        emit Executed(data, accountId);
        emit SpanNetUnwind(accountId, usdcReceived, gasleft());
    }
}
