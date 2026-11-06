// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {PortfolioMarginHook} from "../src/PortfolioMarginHook.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract HookTest is BaseTest {
    address internal constant POOL_MANAGER = address(0x9001);
    PortfolioMarginHook internal hook;

    function setUp() public override {
        super.setUp();
        hook = new PortfolioMarginHook(IPoolManager(POOL_MANAGER), address(engine));
    }

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _params(int256 delta)
        internal
        pure
        returns (IPoolManager.ModifyLiquidityParams memory)
    {
        return IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: delta,
            salt: bytes32(0)
        });
    }

    function _remove(uint256 tokenId) internal {
        vm.prank(POOL_MANAGER);
        hook.beforeRemoveLiquidity(address(this), _key(), _params(-1e18), abi.encode(tokenId));
    }

    function _addNegative(uint256 tokenId) internal {
        vm.prank(POOL_MANAGER);
        hook.beforeAddLiquidity(address(this), _key(), _params(-1e18), abi.encode(tokenId));
    }

    function test_permissionsMatchDesign() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeSwap);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
    }

    function test_lockPositionRecordsOwner() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit PortfolioMarginHook.PositionLocked(lpTokenId, ACCOUNT);

        hook.lockPosition(lpTokenId, ACCOUNT);
        assertTrue(hook.locked(lpTokenId));
        assertEq(hook.lockedTo(lpTokenId), ACCOUNT);
    }

    function test_onlyEngineOrOwnerCanLock() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(PortfolioMarginHook.NotAuthorized.selector);
        hook.lockPosition(lpTokenId, ACCOUNT);
    }

    function test_engineCanLock() public {
        vm.prank(address(engine));
        hook.lockPosition(lpTokenId, ACCOUNT);
        assertTrue(hook.locked(lpTokenId));
    }

    function test_unlockPosition() public {
        hook.lockPosition(lpTokenId, ACCOUNT);
        vm.expectEmit(true, false, false, true, address(hook));
        emit PortfolioMarginHook.Unlocked(lpTokenId);
        hook.unlockPosition(lpTokenId);
        assertFalse(hook.locked(lpTokenId));
    }

    function test_removeRevertsWhileDebtOutstanding() public {
        hook.lockPosition(lpTokenId, ACCOUNT);
        _draw(100e18);

        vm.expectRevert(PortfolioMarginHook.SpanMarginBreach.selector);
        _remove(lpTokenId);
    }

    function test_negativeDeltaAddRevertsWhileDebtOutstanding() public {
        hook.lockPosition(lpTokenId, ACCOUNT);
        _draw(100e18);

        vm.expectRevert(PortfolioMarginHook.SpanMarginBreach.selector);
        _addNegative(lpTokenId);
    }

    function test_positiveDeltaAddAllowedWhileDebtOutstanding() public {
        hook.lockPosition(lpTokenId, ACCOUNT);
        _draw(100e18);

        vm.prank(POOL_MANAGER);
        bytes4 selector =
            hook.beforeAddLiquidity(address(this), _key(), _params(1e18), abi.encode(lpTokenId));
        assertEq(selector, IHooks.beforeAddLiquidity.selector);
    }

    function test_removalAllowedAfterFullRepay() public {
        hook.lockPosition(lpTokenId, ACCOUNT);
        _draw(100e18);

        vm.prank(borrower);
        engine.repay(ACCOUNT, 100e18);

        _remove(lpTokenId);
    }

    function test_removalAllowedWhenDebtZero() public {
        hook.lockPosition(lpTokenId, ACCOUNT);
        _remove(lpTokenId);
    }

    function test_unlockedTokenRemovalAllowed() public {
        _draw(100e18);
        _remove(lpTokenId + 1);
    }

    function test_missingHookDataReverts() public {
        hook.lockPosition(lpTokenId, ACCOUNT);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(PortfolioMarginHook.MissingHookData.selector);
        hook.beforeRemoveLiquidity(address(this), _key(), _params(-1e18), bytes(""));
    }

    function test_engineSetterOnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(PortfolioMarginHook.NotAuthorized.selector);
        hook.setEngine(address(0xBEEF));

        hook.setEngine(address(0xBEEF));
        assertEq(hook.engine(), address(0xBEEF));
    }

    function test_hookCallsOnlyFromPoolManager() public {
        hook.lockPosition(lpTokenId, ACCOUNT);
        _draw(100e18);

        vm.expectRevert();
        hook.beforeRemoveLiquidity(address(this), _key(), _params(-1e18), abi.encode(lpTokenId));
    }
}
