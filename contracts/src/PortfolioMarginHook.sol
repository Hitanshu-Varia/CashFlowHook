// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

interface ICreditEngineDebt {
    function debtOf(uint256 accountId) external view returns (uint256);
}

/// @title PortfolioMarginHook
/// @notice Uniswap v4 hook that locks an LP position while the owning account carries debt.
/// @dev The PositionManager passes the tokenId in `hookData` (abi.encode(uint256 tokenId)).
///      Any liquidity decrease for a locked position with debt > 0 reverts SpanMarginBreach.
contract PortfolioMarginHook is BaseHook {
    address public owner;
    address public engine;
    mapping(uint256 tokenId => bool) public locked;
    mapping(uint256 tokenId => uint256 accountId) public lockedTo;

    event PositionLocked(uint256 indexed tokenId, uint256 indexed accountId);
    event Unlocked(uint256 indexed tokenId);
    event EngineSet(address indexed engine);

    error SpanMarginBreach();
    error MissingHookData();
    error NotAuthorized();

    modifier onlyEngineOrOwner() {
        if (msg.sender != engine && msg.sender != owner) revert NotAuthorized();
        _;
    }

    constructor(IPoolManager poolManager_, address engine_)
        BaseHook(poolManager_)
    {
        owner = msg.sender;
        engine = engine_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function setEngine(address engine_) external {
        if (msg.sender != owner) revert NotAuthorized();
        engine = engine_;
        emit EngineSet(engine_);
    }

    function lockPosition(uint256 tokenId, uint256 accountId) external onlyEngineOrOwner {
        locked[tokenId] = true;
        lockedTo[tokenId] = accountId;
        emit PositionLocked(tokenId, accountId);
    }

    function unlockPosition(uint256 tokenId) external onlyEngineOrOwner {
        locked[tokenId] = false;
        emit Unlocked(tokenId);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal view override returns (bytes4) {
        if (params.liquidityDelta < 0) {
            _guard(hookData);
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal view override returns (bytes4) {
        _guard(hookData);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _guard(bytes calldata hookData) internal view {
        if (hookData.length < 32) revert MissingHookData();
        uint256 tokenId = abi.decode(hookData, (uint256));
        if (!locked[tokenId]) return;
        if (ICreditEngineDebt(engine).debtOf(lockedTo[tokenId]) > 0) revert SpanMarginBreach();
    }
}
