// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRwaCollateralAdapter} from "./interfaces/IRwaCollateralAdapter.sol";

/// @title NavSignalOracle
/// @notice Trusted-signer NAV record oracle for OUSG/USDY-style treasury state.
/// @dev MVP only. The source transaction hash is pinned so a judge can verify the read;
///      production path is a multi-oracle / issuer-signed feed (docs/limits.md).
contract NavSignalOracle {
    struct NavRecord {
        address asset;
        uint256 navPerShareWad;
        uint256 accrualPerSecondWad;
        uint64 observedAt;
        bool gateOpen;
        bytes32 sourceTxHash;
    }

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAV_TYPEHASH = keccak256(
        "NavRecord(address asset,uint256 navPerShareWad,uint256 accrualPerSecondWad,uint64 observedAt,bool gateOpen,bytes32 sourceTxHash)"
    );
    bytes32 private constant NAME_HASH = keccak256("CashflowHook");
    bytes32 private constant VERSION_HASH = keccak256("1");
    uint256 private constant SECP256K1N_DIV_2 =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    address public owner;
    address public navSigner;
    address public adapter;
    mapping(address => uint64) public lastObservedAt;
    mapping(address => NavRecord) internal _latest;

    event NavPosted(
        address indexed asset,
        uint256 navPerShareWad,
        uint256 accrualPerSecondWad,
        bytes32 sourceTxHash,
        uint64 observedAt,
        bool gateOpen
    );
    event SignerSet(address indexed signer);
    event AdapterSet(address indexed adapter);

    error NotAuthorized();
    error StaleObservation();
    error BadSignature();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    constructor(address signer, address adapter_) {
        owner = msg.sender;
        navSigner = signer;
        adapter = adapter_;
    }

    function setSigner(address signer) external onlyOwner {
        navSigner = signer;
        emit SignerSet(signer);
    }

    function setAdapter(address adapter_) external onlyOwner {
        adapter = adapter_;
        emit AdapterSet(adapter_);
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    function hashNavRecord(NavRecord memory r) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                NAV_TYPEHASH,
                r.asset,
                r.navPerShareWad,
                r.accrualPerSecondWad,
                r.observedAt,
                r.gateOpen,
                r.sourceTxHash
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function postNav(bytes calldata sig, NavRecord calldata r) external {
        if (r.observedAt <= lastObservedAt[r.asset]) revert StaleObservation();

        bytes32 digest = hashNavRecord(r);
        address recovered = _recover(digest, sig);
        if (recovered != navSigner) revert BadSignature();

        lastObservedAt[r.asset] = r.observedAt;
        _latest[r.asset] = r;

        if (adapter != address(0)) {
            IRwaCollateralAdapter(adapter).applyNav(
                r.asset,
                r.navPerShareWad,
                r.accrualPerSecondWad,
                r.observedAt,
                r.gateOpen,
                r.sourceTxHash
            );
        }

        emit NavPosted(
            r.asset,
            r.navPerShareWad,
            r.accrualPerSecondWad,
            r.sourceTxHash,
            r.observedAt,
            r.gateOpen
        );
    }

    function latest(address asset) external view returns (NavRecord memory) {
        return _latest[asset];
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) revert BadSignature();
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        // Reject malleable signatures: high-s and v outside {27,28}.
        if (uint256(s) > SECP256K1N_DIV_2) revert BadSignature();
        if (v != 27 && v != 28) revert BadSignature();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
        return signer;
    }
}
