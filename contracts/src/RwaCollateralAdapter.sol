// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRwaCollateralAdapter, RwaPositionView} from "./interfaces/IRwaCollateralAdapter.sol";

/// @title RwaCollateralAdapter
/// @notice The only contract that knows tokenized-equity and tokenized-treasury specifics.
/// @dev R1 marks are pushed by a mark oracle; R2 NAV records are pushed by NavSignalOracle.
///      Permissioned/KYC assets are never held by this repo; only public NAV state is read.
contract RwaCollateralAdapter is IRwaCollateralAdapter {
    struct Asset {
        uint8 class; // 1 = equity, 2 = treasury
        bool transferRestricted;
        uint8 decimals;
        bool permissioned;
        uint256 mark;
        uint64 markTs;
        uint256 navPerShareWad;
        uint256 accrualPerSecondWad;
        uint64 navTs;
        bool gateOpen;
        bytes32 sourceTxHash;
        bool exists;
    }

    address public owner;
    address public navOracle;
    address public markOracle;
    mapping(address => Asset) internal _assets;

    event AssetRegistered(address indexed asset, uint8 class, bool transferRestricted, uint8 decimals);
    event EquityMarkSet(address indexed asset, uint256 mark, uint64 markTs);
    event NavApplied(
        address indexed asset,
        uint256 navPerShareWad,
        uint256 accrualPerSecondWad,
        uint64 navTs,
        bool gateOpen,
        bytes32 sourceTxHash
    );
    event NavOracleSet(address indexed oracle);
    event MarkOracleSet(address indexed oracle);

    error NotAuthorized();
    error AssetUnknown();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setNavOracle(address oracle) external onlyOwner {
        navOracle = oracle;
        emit NavOracleSet(oracle);
    }

    function setMarkOracle(address oracle) external onlyOwner {
        markOracle = oracle;
        emit MarkOracleSet(oracle);
    }

    function registerAsset(
        address asset,
        uint8 class_,
        bool transferRestricted_,
        uint8 decimals_,
        bool permissioned_
    ) external onlyOwner {
        require(class_ == 1 || class_ == 2, "bad class");
        _assets[asset] = Asset({
            class: class_,
            transferRestricted: transferRestricted_,
            decimals: decimals_,
            permissioned: permissioned_,
            mark: 0,
            markTs: 0,
            navPerShareWad: 0,
            accrualPerSecondWad: 0,
            navTs: 0,
            gateOpen: false,
            sourceTxHash: bytes32(0),
            exists: true
        });
        emit AssetRegistered(asset, class_, transferRestricted_, decimals_);
    }

    function setTransferRestricted(address asset, bool restricted) external onlyOwner {
        Asset storage a = _assets[asset];
        if (!a.exists) revert AssetUnknown();
        a.transferRestricted = restricted;
    }

    function setEquityMark(address asset, uint256 markWad, uint64 markTs) external {
        if (msg.sender != owner && msg.sender != markOracle) revert NotAuthorized();
        Asset storage a = _assets[asset];
        if (!a.exists) revert AssetUnknown();
        a.mark = markWad;
        a.markTs = markTs;
        emit EquityMarkSet(asset, markWad, markTs);
    }

    function applyNav(
        address asset,
        uint256 navPerShareWad,
        uint256 accrualPerSecondWad,
        uint64 navTs,
        bool gateOpen,
        bytes32 sourceTxHash
    ) external {
        if (msg.sender != navOracle) revert NotAuthorized();
        Asset storage a = _assets[asset];
        if (!a.exists) revert AssetUnknown();
        a.navPerShareWad = navPerShareWad;
        a.accrualPerSecondWad = accrualPerSecondWad;
        a.navTs = navTs;
        a.gateOpen = gateOpen;
        a.sourceTxHash = sourceTxHash;
        emit NavApplied(asset, navPerShareWad, accrualPerSecondWad, navTs, gateOpen, sourceTxHash);
    }

    function positionValue(address asset, uint256)
        external
        view
        returns (RwaPositionView memory)
    {
        Asset memory a = _assets[asset];
        if (!a.exists) revert AssetUnknown();
        return RwaPositionView({
            class: a.class,
            transferRestricted: a.transferRestricted,
            decimals: a.decimals,
            mark: a.mark,
            markTs: a.markTs,
            navPerShareWad: a.navPerShareWad,
            accrualPerSecondWad: a.accrualPerSecondWad,
            navTs: a.navTs,
            gateOpen: a.gateOpen,
            sourceTxHash: a.sourceTxHash
        });
    }

    function transferRestricted(address asset) external view returns (bool) {
        Asset memory a = _assets[asset];
        if (!a.exists) revert AssetUnknown();
        return a.transferRestricted;
    }

    function assetClass(address asset) external view returns (uint8) {
        return _assets[asset].class;
    }

    /// @notice Normalize a raw token amount to WAD using the asset's registered decimals.
    function toWad(address asset, uint256 rawAmount) external view returns (uint256) {
        Asset memory a = _assets[asset];
        if (!a.exists) revert AssetUnknown();
        if (a.decimals == 18) return rawAmount;
        if (a.decimals < 18) return rawAmount * (10 ** (18 - a.decimals));
        return rawAmount / (10 ** (a.decimals - 18));
    }
}
