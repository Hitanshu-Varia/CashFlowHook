// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Normalized view of an RWA position. `class` is 1 (equity) or 2 (treasury).
struct RwaPositionView {
    uint8 class;
    bool transferRestricted;
    uint8 decimals;
    uint256 mark;
    uint64 markTs;
    uint256 navPerShareWad;
    uint256 accrualPerSecondWad;
    uint64 navTs;
    bool gateOpen;
    bytes32 sourceTxHash;
}

interface IRwaCollateralAdapter {
    function positionValue(address asset, uint256 amountWad)
        external
        view
        returns (RwaPositionView memory);

    function transferRestricted(address asset) external view returns (bool);

    function applyNav(
        address asset,
        uint256 navPerShareWad,
        uint256 accrualPerSecondWad,
        uint64 navTs,
        bool gateOpen,
        bytes32 sourceTxHash
    ) external;
}
