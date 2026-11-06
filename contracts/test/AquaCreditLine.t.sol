// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {CreditEngine} from "../src/CreditEngine.sol";
import {AquaCreditLine} from "../src/AquaCreditLine.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract AquaCreditLineTest is BaseTest {
    MockERC20 internal token;

    function setUp() public override {
        super.setUp();
        token = new MockERC20();
        token.mint(borrower, 1_000e18);
    }

    function test_openAccountOnlyOwner() public {
        vm.prank(borrower);
        line.openAccount(ACCOUNT);

        vm.prank(agent);
        vm.expectRevert(AquaCreditLine.NotAuthorized.selector);
        line.openAccount(ACCOUNT);
    }

    function test_drawCreditsVirtualBalance() public {
        vm.prank(borrower);
        line.draw(ACCOUNT, 100e18);

        assertEq(engine.debtOf(ACCOUNT), 100e18);
        assertEq(line.creditLineOf(ACCOUNT), 100e18);
        assertEq(line.aquaBalanceOf(ACCOUNT), 100e18);
        assertEq(aqua.rawBalances(ACCOUNT), 100e18);
    }

    function test_repayDebitsVirtualBalanceAndClamps() public {
        vm.prank(borrower);
        line.draw(ACCOUNT, 100e18);

        vm.prank(borrower);
        line.repay(ACCOUNT, 40e18);
        assertEq(engine.debtOf(ACCOUNT), 60e18);
        assertEq(line.aquaBalanceOf(ACCOUNT), 60e18);

        vm.prank(borrower);
        line.repay(ACCOUNT, 1_000e18);
        assertEq(engine.debtOf(ACCOUNT), 0);
        assertEq(line.aquaBalanceOf(ACCOUNT), 0);
    }

    function test_nonOwnerCannotDrawOrRepay() public {
        vm.prank(agent);
        vm.expectRevert(AquaCreditLine.NotAuthorized.selector);
        line.draw(ACCOUNT, 1e18);

        _draw(10e18);
        vm.prank(agent);
        vm.expectRevert(AquaCreditLine.NotAuthorized.selector);
        line.repay(ACCOUNT, 1e18);
    }

    function test_drawAboveBpReverts() public {
        uint256 bp = engine.computeBp(ACCOUNT);
        vm.prank(borrower);
        vm.expectRevert(CreditEngine.DebtExceedsBp.selector);
        line.draw(ACCOUNT, bp + 1);
    }

    function test_noTokenCustodyTransfer() public {
        uint256 borrowerBefore = token.balanceOf(borrower);
        uint256 engineBefore = token.balanceOf(address(engine));
        uint256 lineBefore = token.balanceOf(address(line));
        uint256 aquaBefore = token.balanceOf(address(aqua));

        vm.prank(borrower);
        line.draw(ACCOUNT, 250e18);
        vm.prank(borrower);
        line.repay(ACCOUNT, 100e18);

        assertEq(token.balanceOf(borrower), borrowerBefore);
        assertEq(token.balanceOf(address(engine)), engineBefore);
        assertEq(token.balanceOf(address(line)), lineBefore);
        assertEq(token.balanceOf(address(aqua)), aquaBefore);
    }

    function testFuzz_lifecycleNeverExceedsBp(uint256 amount) public {
        uint256 bp = engine.computeBp(ACCOUNT);
        amount = bound(amount, 1, bp);

        vm.prank(borrower);
        line.draw(ACCOUNT, amount);
        assertLe(engine.debtOf(ACCOUNT), bp);
        assertEq(line.aquaBalanceOf(ACCOUNT), amount);

        vm.prank(borrower);
        line.repay(ACCOUNT, amount / 2);
        assertEq(engine.debtOf(ACCOUNT), amount - amount / 2);
        assertEq(line.aquaBalanceOf(ACCOUNT), amount - amount / 2);
    }
}
