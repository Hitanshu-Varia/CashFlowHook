// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReceiptsRegistry} from "../src/ReceiptsRegistry.sol";

contract ReceiptsRegistryTest is Test {
    ReceiptsRegistry internal registry;
    address internal account = address(0xB0B);
    address internal agent = address(0xA9E);
    address internal payee = address(0xCAFE);
    bytes32 internal constant MEMO = keccak256("x402:bill:1");

    function setUp() public {
        registry = new ReceiptsRegistry();
    }

    function test_ownerRecordsReceipt() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit ReceiptsRegistry.AgentSpent(account, payee, 5e18, MEMO, uint64(block.timestamp));

        vm.prank(account);
        registry.record(account, payee, 5e18, MEMO);

        assertEq(registry.receiptCount(account), 1);
        ReceiptsRegistry.Receipt memory r = registry.receiptAt(account, 0);
        assertEq(r.account, account);
        assertEq(r.to, payee);
        assertEq(r.amount, 5e18);
        assertEq(r.memo, MEMO);
        assertEq(r.ts, uint64(block.timestamp));
    }

    function test_agentRecordsReceipt() public {
        vm.prank(account);
        registry.setAgent(agent, true);

        vm.prank(agent);
        registry.record(account, payee, 1e18, MEMO);

        assertEq(registry.receiptCount(account), 1);
        assertTrue(registry.agents(account, agent));
    }

    function test_unauthorizedRecorderReverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ReceiptsRegistry.NotAuthorized.selector);
        registry.record(account, payee, 1e18, MEMO);
    }

    function test_revokedAgentCannotRecord() public {
        vm.prank(account);
        registry.setAgent(agent, true);
        vm.prank(account);
        registry.setAgent(agent, false);

        vm.prank(agent);
        vm.expectRevert(ReceiptsRegistry.NotAuthorized.selector);
        registry.record(account, payee, 1e18, MEMO);
    }

    function test_spendObservedUsesSameAuthorization() public {
        vm.prank(account);
        registry.setAgent(agent, true);

        vm.prank(agent);
        registry.spendObserved(account, payee, 2e18, MEMO);
        assertEq(registry.receiptCount(account), 1);

        vm.prank(address(0xBAD));
        vm.expectRevert(ReceiptsRegistry.NotAuthorized.selector);
        registry.spendObserved(account, payee, 2e18, MEMO);
    }

    function test_receiptsAreAppendOnlyAndPerAccount() public {
        vm.prank(account);
        registry.setAgent(agent, true);

        vm.startPrank(agent);
        registry.record(account, payee, 1e18, keccak256("m1"));
        registry.record(account, payee, 2e18, keccak256("m2"));
        vm.stopPrank();

        assertEq(registry.receiptCount(account), 2);
        assertEq(registry.receiptAt(account, 0).amount, 1e18);
        assertEq(registry.receiptAt(account, 1).amount, 2e18);
        assertEq(registry.receiptCount(address(0xBEEF)), 0);
    }

    function testFuzz_receiptAmountRoundTrips(uint128 amount) public {
        vm.prank(account);
        registry.record(account, payee, amount, MEMO);
        assertEq(registry.receiptAt(account, 0).amount, amount);
    }
}
