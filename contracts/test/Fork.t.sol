// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./BaseTest.sol";
import {RwaPositionView} from "../src/interfaces/IRwaCollateralAdapter.sol";

interface IERC20Metadata {
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
}

/// @notice Base-mainnet fork lifecycle. Skipped unless RPC_FORK_URL is set.
contract ForkLifecycleTest is BaseTest {
    function setUp() public override {
        string memory rpc = vm.envOr("RPC_FORK_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        super.setUp();
    }

    function test_fork_baseAddressesHaveCode() public view {
        address poolManager = vm.envOr("POOL_MANAGER_BASE", address(0));
        address positionManager = vm.envOr("POSITION_MANAGER_BASE", address(0));
        address aqua = vm.envOr("AQUA_ADDR", address(0));

        if (poolManager == address(0) && positionManager == address(0) && aqua == address(0)) {
            return;
        }
        if (poolManager != address(0)) assertGt(poolManager.code.length, 0);
        if (positionManager != address(0)) assertGt(positionManager.code.length, 0);
        if (aqua != address(0)) assertGt(aqua.code.length, 0);
    }

    function test_fork_realStockTokenIsReadable() public {
        address stock = vm.envOr("STOCK_TOKEN_BASE", address(0));
        uint256 mark = vm.envOr("STOCK_MARK_WAD", uint256(0));
        if (stock == address(0) || mark == 0) {
            vm.skip(true);
            return;
        }

        assertGt(stock.code.length, 0);
        uint8 decimals = IERC20Metadata(stock).decimals();

        adapter.registerAsset(stock, 1, false, decimals, false);
        adapter.setEquityMark(stock, mark, uint64(block.timestamp));
        RwaPositionView memory v = adapter.positionValue(stock, 1e18);
        assertEq(v.class, 1);
        assertEq(v.mark, mark);
        assertEq(v.decimals, decimals);
    }

    function test_fork_fullLifecycleWithRwaLegs() public {
        // Both restricted legs are excluded: only stock + LP can back an unwind.
        adapter.setTransferRestricted(equityAsset, true);
        engine.refreshMarks(ACCOUNT);
        engine.setGateState(ACCOUNT, false);

        (, uint256 unwindable,,) = _breakdown();
        assertEq(unwindable, 1550e18);

        _draw(1600e18);
        verifier.acceptLockedRisk(
            borrower, ACCOUNT, keccak256("fork-locked-risk"), uint64(block.timestamp + 1 hours)
        );

        liquidity.setProceeds(1600e18);
        engine.unwind(ACCOUNT);

        assertEq(engine.debtOf(ACCOUNT), 0);
        (, unwindable,,) = _breakdown();
        assertEq(unwindable, 0);
    }

    function test_fork_drawRepayLifecycle() public {
        _draw(500e18);
        assertEq(engine.debtOf(ACCOUNT), 500e18);

        vm.prank(borrower);
        engine.repay(ACCOUNT, 500e18);
        assertEq(engine.debtOf(ACCOUNT), 0);
    }
}

/// @notice Ethereum-mainnet NAV source read. Skipped unless RPC_ETH_MAINNET is set.
contract NavForkTest is Test {
    function test_fork_mainnetNavAssetsAreReadable() public {
        string memory rpc = vm.envOr("RPC_ETH_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        address ousg = vm.envOr("OUSG_ADDR_ETH", address(0));
        address usdy = vm.envOr("USDY_ADDR_ETH", address(0));
        if (ousg == address(0) && usdy == address(0)) {
            vm.skip(true);
            return;
        }

        if (ousg != address(0)) {
            assertGt(ousg.code.length, 0);
            assertGt(IERC20Metadata(ousg).totalSupply(), 0);
        }
        if (usdy != address(0)) {
            assertGt(usdy.code.length, 0);
            assertGt(IERC20Metadata(usdy).totalSupply(), 0);
        }
    }
}
