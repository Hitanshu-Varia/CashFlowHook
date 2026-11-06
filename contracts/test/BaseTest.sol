// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditEngine} from "../src/CreditEngine.sol";
import {SpanMathLib} from "../src/SpanMathLib.sol";
import {MarkFeed} from "../src/MarkFeed.sol";
import {FeeStreamOracle} from "../src/FeeStreamOracle.sol";
import {StrategyBureau} from "../src/StrategyBureau.sol";
import {RwaCollateralAdapter} from "../src/RwaCollateralAdapter.sol";
import {NavSignalOracle} from "../src/NavSignalOracle.sol";
import {AgentPassVerifier} from "../src/AgentPassVerifier.sol";
import {ReceiptsRegistry} from "../src/ReceiptsRegistry.sol";
import {AquaCreditLine} from "../src/AquaCreditLine.sol";
import {MockAqua} from "../src/mocks/MockAqua.sol";
import {MockLiquidity} from "../src/mocks/MockLiquidity.sol";
import {SpanVMRouter} from "../src/SpanVMRouter.sol";

abstract contract BaseTest is Test {
    uint256 internal constant FEE_PK = 0xFEE;
    uint256 internal constant NAV_PK = 0x1234;
    uint256 internal constant ACCOUNT = 1;

    uint256 internal constant STOCK_UNITS = 10e18;
    uint256 internal constant STOCK_MARK = 100e18;
    uint256 internal constant LP_UNITS = 20e18;
    uint256 internal constant LP_MARK = 50e18;
    uint256 internal constant R1_UNITS = 10e18;
    uint256 internal constant R1_MARK = 100e18;
    uint256 internal constant R2_UNITS = 1000e18;
    uint256 internal constant NAV = 1e18;
    uint256 internal constant ACCRUAL_PER_SEC = 1e12;

    address internal borrower = address(0xB0B);
    address internal agent = address(0xA9E);
    address internal stockToken = address(0x510CC);
    address internal equityAsset = address(0xE001);
    address internal treasuryAsset = address(0x7EA5);
    uint256 internal lpTokenId = 42;

    MarkFeed internal markFeed;
    StrategyBureau internal bureau;
    FeeStreamOracle internal feeOracle;
    RwaCollateralAdapter internal adapter;
    NavSignalOracle internal navOracle;
    CreditEngine internal engine;
    AgentPassVerifier internal verifier;
    ReceiptsRegistry internal receipts;
    MockAqua internal aqua;
    AquaCreditLine internal line;
    MockLiquidity internal liquidity;
    SpanVMRouter internal router;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 100 ether);
        vm.deal(borrower, 100 ether);

        markFeed = new MarkFeed();
        bureau = new StrategyBureau(address(this));
        feeOracle = new FeeStreamOracle(vm.addr(FEE_PK), address(bureau));
        bureau.setOracle(address(feeOracle));

        adapter = new RwaCollateralAdapter();
        navOracle = new NavSignalOracle(vm.addr(NAV_PK), address(adapter));
        adapter.setNavOracle(address(navOracle));

        engine = new CreditEngine(
            address(markFeed),
            address(feeOracle),
            address(0),
            address(adapter),
            address(navOracle),
            address(0),
            address(0)
        );

        verifier = new AgentPassVerifier(address(this), address(engine));
        engine.setAgentVerifier(address(verifier));

        liquidity = new MockLiquidity();
        router = new SpanVMRouter(address(engine), address(liquidity));
        engine.setRouter(address(router));

        aqua = new MockAqua();
        line = new AquaCreditLine(address(engine), address(aqua));
        engine.setLine(address(line));

        receipts = new ReceiptsRegistry();

        markFeed.setMark(bytes32(uint256(uint160(stockToken))), STOCK_MARK, uint64(block.timestamp));
        markFeed.setMark(bytes32(lpTokenId), LP_MARK, uint64(block.timestamp));

        adapter.registerAsset(equityAsset, 1, false, 18, false);
        adapter.setEquityMark(equityAsset, R1_MARK, uint64(block.timestamp));
        adapter.registerAsset(treasuryAsset, 2, false, 18, true);
        vm.prank(address(navOracle));
        adapter.applyNav(
            treasuryAsset,
            NAV,
            ACCRUAL_PER_SEC,
            uint64(block.timestamp),
            true,
            keccak256("nav-source")
        );

        vm.prank(borrower);
        engine.onboard(ACCOUNT, stockToken, STOCK_UNITS, lpTokenId, LP_UNITS);
        vm.prank(borrower);
        engine.setAgent(ACCOUNT, agent);
        vm.prank(borrower);
        engine.setRwaPosition(ACCOUNT, equityAsset, R1_UNITS);
        vm.prank(borrower);
        engine.setRwaPosition(ACCOUNT, treasuryAsset, R2_UNITS);
        vm.prank(borrower);
        engine.registerUnwinder(ACCOUNT, address(this));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sample() internal pure returns (bytes32[] memory sample) {
        sample = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            sample[i] = bytes32(uint256(uint160(address(uint160(0x1000 + i)))));
        }
    }

    function _feeRecord(uint64 windowStart, uint256 daily)
        internal
        view
        returns (FeeStreamOracle.StreamRecord memory r, bytes32[] memory sample)
    {
        sample = _sample();
        r = FeeStreamOracle.StreamRecord({
            strategyPosId: bytes32(lpTokenId),
            windowStartTs: windowStart,
            dailyFees: [daily, daily, daily, daily, daily, daily, daily],
            distinctTakers: 10,
            excludedOwner: address(0xB0B),
            rootHash: keccak256(abi.encode(sample))
        });
    }

    function _postFeeRecord(uint256 daily) internal {
        (FeeStreamOracle.StreamRecord memory r, bytes32[] memory sample) =
            _feeRecord(uint64(block.timestamp - 7 days), daily);
        feeOracle.postRecord(_sign(FEE_PK, feeOracle.hashRecord(r)), r, sample);
    }

    function _postNav(uint64 observedAt, bool gateOpen, uint256 accrualPerSecond) internal {
        NavSignalOracle.NavRecord memory r = NavSignalOracle.NavRecord({
            asset: treasuryAsset,
            navPerShareWad: NAV,
            accrualPerSecondWad: accrualPerSecond,
            observedAt: observedAt,
            gateOpen: gateOpen,
            sourceTxHash: keccak256(abi.encode("source", observedAt))
        });
        navOracle.postNav(_sign(NAV_PK, navOracle.hashNavRecord(r)), r);
    }

    function _draw(uint256 amount) internal {
        vm.prank(borrower);
        engine.draw(ACCOUNT, amount);
    }

    function _breakdown()
        internal
        view
        returns (uint256 bp, uint256 unwindable, uint256 locked, uint256 health)
    {
        return engine.marginBreakdown(ACCOUNT);
    }
}
