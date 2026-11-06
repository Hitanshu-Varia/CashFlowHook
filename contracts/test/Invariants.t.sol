// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./BaseTest.sol";
import {CreditEngine} from "../src/CreditEngine.sol";
import {MarkFeed} from "../src/MarkFeed.sol";
import {RwaCollateralAdapter} from "../src/RwaCollateralAdapter.sol";
import {StrategyBureau} from "../src/StrategyBureau.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Actor driver for I2 / I9 / I11 / I13-style state exploration.
contract EngineHandler is Test {
    uint256 internal constant ACCOUNT = 2;
    uint256 internal constant STOCK_UNITS = 10e18;
    uint256 internal constant STOCK_MARK = 100e18;
    uint256 internal constant LP_TOKEN_ID = 42;
    uint256 internal constant LP_UNITS = 20e18;
    uint256 internal constant LP_MARK = 50e18;
    uint256 internal constant R1_UNITS = 10e18;
    uint256 internal constant R1_MARK = 100e18;
    uint256 internal constant R2_UNITS = 1000e18;

    address internal constant STOCK_TOKEN = address(0x510CC);
    address internal constant EQUITY_ASSET = address(0xE001);
    address internal constant TREASURY_ASSET = address(0x7EA5);
    bytes32 internal constant STOCK_KEY = bytes32(uint256(uint160(STOCK_TOKEN)));
    bytes32 internal constant LP_KEY = bytes32(LP_TOKEN_ID);

    CreditEngine public engine;
    MarkFeed public markFeed;
    RwaCollateralAdapter public adapter;

    constructor(CreditEngine engine_, MarkFeed markFeed_, RwaCollateralAdapter adapter_) {
        engine = engine_;
        markFeed = markFeed_;
        adapter = adapter_;

        engine.onboard(ACCOUNT, STOCK_TOKEN, STOCK_UNITS, LP_TOKEN_ID, LP_UNITS);
        engine.setRwaPosition(ACCOUNT, EQUITY_ASSET, R1_UNITS);
        engine.setRwaPosition(ACCOUNT, TREASURY_ASSET, R2_UNITS);
    }

    function draw(uint256 amount) external {
        uint256 bp = engine.computeBp(ACCOUNT);
        uint256 debt = engine.debtOf(ACCOUNT);
        if (bp <= debt) return;
        amount = bound(amount, 1, bp - debt);
        engine.draw(ACCOUNT, amount);
    }

    function agentDraw(uint256 amount) external {
        uint256 bp = engine.computeBp(ACCOUNT);
        uint256 cap = (bp * 200) / 10_000;
        if (cap == 0) return;
        amount = bound(amount, 1, cap);
        try engine.agentDraw(ACCOUNT, amount) {} catch {}
    }

    function repay(uint256 amount) external {
        uint256 debt = engine.debtOf(ACCOUNT);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        engine.repay(ACCOUNT, amount);
    }

    function accrue() external {
        try engine.accrueCoupon(ACCOUNT) {} catch {}
    }

    function setGate(bool open) external {
        engine.setGateState(ACCOUNT, open);
    }

    function warp(uint256 secondsForward) external {
        secondsForward = bound(secondsForward, 1, 20_000);
        vm.warp(block.timestamp + secondsForward);
        _refreshSources();
    }

    function refresh() external {
        _refreshSources();
    }

    function _refreshSources() internal {
        markFeed.setMark(STOCK_KEY, STOCK_MARK, uint64(block.timestamp));
        markFeed.setMark(LP_KEY, LP_MARK, uint64(block.timestamp));
        adapter.setEquityMark(EQUITY_ASSET, R1_MARK, uint64(block.timestamp));
        engine.refreshMarks(ACCOUNT);
    }
}

/// @notice Actor driver for StrategyBureau append-only history (I10).
contract BureauHandler is Test {
    bytes32 internal constant ID = keccak256("invariant-strategy");
    StrategyBureau public bureau;

    constructor(StrategyBureau bureau_) {
        bureau = bureau_;
    }

    function post(uint16 score) external {
        vm.warp(block.timestamp + 1);
        bureau.postScore(ID, score, 10);
    }
}

contract InvariantsTest is BaseTest {
    EngineHandler internal handler;
    BureauHandler internal bureauHandler;
    MockERC20 internal token;

    function setUp() public override {
        super.setUp();

        handler = new EngineHandler(engine, markFeed, adapter);
        markFeed.setWriter(address(handler), true);
        adapter.setMarkOracle(address(handler));
        engine.setKeeper(address(handler));

        bureauHandler = new BureauHandler(bureau);
        bureau.setOracle(address(bureauHandler));

        token = new MockERC20();
        token.mint(borrower, 1_000e18);

        targetContract(address(handler));
        targetContract(address(bureauHandler));
    }

    function invariant_debtNeverExceedsBp() public view {
        assertLe(engine.debtOf(2), engine.computeBp(2));
    }

    function invariant_stateIsNeverInsolvent() public view {
        assertNotEq(uint256(engine.stateOf(2)), uint256(CreditEngine.State.INSOLVENT));
    }

    function invariant_segregationSumsToHaircut() public view {
        CreditEngine.Account memory a = engine.getAccount(2);
        (, uint256 unwindable, uint256 locked,) = engine.marginBreakdown(2);

        uint256 stockUsd = (a.stockAmt * a.stockMark) / 1e18;
        uint256 lpUsd = (a.lpUnits * a.lpMark) / 1e18;
        uint256 r1Usd = (a.equityRwaAmt * a.equityRwaMark) / 1e18;
        uint256 r2Usd = (a.navAmt * a.navPerShareWad) / 1e18;

        uint256 haircut = (stockUsd * 85) / 100 + (lpUsd * 70) / 100 + (r1Usd * 75) / 100
            + (r2Usd * 85) / 100;

        assertEq(unwindable + locked, haircut);
        assertLe(unwindable, haircut);
    }

    function invariant_engineHoldsNoBorrowerTokens() public view {
        assertEq(token.balanceOf(address(engine)), 0);
        assertEq(token.balanceOf(address(line)), 0);
        assertEq(token.balanceOf(address(aqua)), 0);
    }

    function invariant_bureauTimestampsStrictlyIncrease() public view {
        bytes32 id = keccak256("invariant-strategy");
        uint256 n = bureau.recordCount(id);
        if (n == 0) return;
        uint64 previous = bureau.recordAt(id, 0).ts;
        for (uint256 i = 1; i < n; i++) {
            uint64 current = bureau.recordAt(id, i).ts;
            assertGt(current, previous);
            previous = current;
        }
    }

    function invariant_bureauScoreAtMost100() public view {
        bytes32 id = keccak256("invariant-strategy");
        uint256 n = bureau.recordCount(id);
        for (uint256 i = 0; i < n; i++) {
            assertLe(bureau.recordAt(id, i).score, 100);
        }
    }
}
