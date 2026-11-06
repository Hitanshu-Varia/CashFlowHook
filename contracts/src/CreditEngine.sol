// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WadMath} from "./libraries/WadMath.sol";
import {SpanMathLib} from "./SpanMathLib.sol";
import {FeeMathLib} from "./FeeMathLib.sol";
import {IMarkFeed} from "./interfaces/IMarkFeed.sol";
import {IFeeStreamOracle} from "./interfaces/IFeeStreamOracle.sol";
import {IRwaCollateralAdapter, RwaPositionView} from "./interfaces/IRwaCollateralAdapter.sol";
import {IPortfolioMarginHook} from "./interfaces/IPortfolioMarginHook.sol";
import {ISpanRouter} from "./interfaces/ISpanRouter.sol";

/// @title CreditEngine
/// @notice Cross-margined, non-custodial credit line for an autonomous agent. Three collateral
///         classes share one 16-scenario grid; liquidatable and earning-but-locked margin are
///         segregated. The engine never holds borrower tokens.
contract CreditEngine {
    using WadMath for uint256;

    uint256 public constant WAD = 1e18;
    uint256 public constant DEFAULT_CAP_BPS = 200;
    uint16 public constant MAX_DRAWS_PER_WINDOW = 3;
    uint64 public constant DRAW_WINDOW = 12 hours;
    uint64 public constant STEP_UP_EXPIRY = 24 hours;
    uint64 public constant LOCKED_RISK_EXPIRY = 24 hours;
    uint64 public constant MARK_STALE = 1800;
    uint64 public constant NAV_STALE = 93600;
    uint64 public constant COUPON_PERIOD = 86400;
    uint64 public constant ACCRUAL_WINDOW = 604800;
    uint256 public constant DAILY_CAP_PER_INVESTOR = 25_000_000e18;
    uint256 public constant LTV_MAX = 0.80e18;
    uint256 public constant MAINT = 0.85e18;

    enum State {
        EMPTY,
        PRICED,
        ACTIVE,
        STRESSED,
        UNWINDING,
        INSOLVENT
    }

    struct Autonomy {
        uint128 capWad;
        uint16 capBps;
        uint16 capCountPer12h;
        uint16 spent;
        uint64 windowStart;
        uint64 expiresAt;
        bool needsStepUp;
    }

    struct Account {
        address owner;
        address agent;
        address stockToken;
        uint256 stockAmt;
        uint256 stockMark;
        uint64 stockMarkTs;
        uint256 lpTokenId;
        uint256 lpUnits;
        uint256 lpMark;
        uint64 lpMarkTs;
        bool lpLocked;
        address rwaAssetR1;
        uint256 equityRwaAmt;
        uint256 equityRwaMark;
        bool r1TransferRestricted;
        uint64 r1MarkTs;
        address rwaAssetR2;
        uint256 navAmt;
        uint256 navPerShareWad;
        uint256 accrualPerSecondWad;
        uint64 lastAccrualTs;
        uint64 navTs;
        bool gateOpen;
        bytes32 rwaSourceTxHash;
        uint256 debtWad;
        uint256 feeCreditFees;
        uint256 navAccrualCredit;
        Autonomy aut;
        address unwinder;
        bool unwinderOk;
        bool lockedRiskAccepted;
        uint64 lockedRiskExpiry;
        bool nonEmpty;
    }

    address public owner;
    address public line;
    address public keeper;
    address public immutable MARK_FEED;
    address public immutable FEE_ORACLE;
    address public agentVerifier;
    address public immutable RWA_ADAPTER;
    address public immutable NAV_ORACLE;
    address public router;
    address public hook;

    mapping(uint256 => Account) internal accounts;
    mapping(bytes32 => bool) public consumedProofs;

    event Onboarded(uint256 indexed accountId, address indexed accountOwner);
    event RwaPositionSet(uint256 indexed accountId, address indexed asset, uint256 amount, uint8 class);
    event MarksRefreshed(uint256 indexed accountId, uint256 stockMark, uint256 lpMark);
    event CouponAccrued(uint256 indexed accountId, uint256 credit, bytes32 sourceTxHash);
    event Drew(uint256 indexed accountId, uint256 amt);
    event Repaid(uint256 indexed accountId, uint256 amt);
    event SteppedUp(uint256 indexed accountId, uint16 capBps, uint64 expiresAt);
    event LockedRiskAccepted(uint256 indexed accountId, uint64 expiresAt);
    event GateShut(uint256 indexed accountId, bool open);
    event SegregationChanged(uint256 unwindableNow, uint256 earningLocked);
    event Unwound(uint256 indexed accountId, uint256 repaid, uint256 badDebt);
    event AgentSet(uint256 indexed accountId, address indexed agent);
    event UnwinderSet(uint256 indexed accountId, address indexed unwinder);
    event LineSet(address indexed line);
    event KeeperSet(address indexed keeper);

    error STALE_MARK();
    error NavStale();
    error DebtExceedsBp();
    error CapExceededBlock();
    error NotHumanApproved();
    error GridOverflow();
    error InsufficientUnwindable();
    error GateShutNoLiquidity();
    error NotFound();
    error NotAuthorized();
    error AlreadyOnboarded();
    error CouponNotMature();
    error UnwindNotEligible();
    error BadDebtProjection();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    constructor(
        address markFeed,
        address feeOracle,
        address agentVerifier_,
        address rwaAdapter,
        address navOracle,
        address router_,
        address hook_
    ) {
        owner = msg.sender;
        keeper = msg.sender;
        MARK_FEED = markFeed;
        FEE_ORACLE = feeOracle;
        agentVerifier = agentVerifier_;
        RWA_ADAPTER = rwaAdapter;
        NAV_ORACLE = navOracle;
        router = router_;
        hook = hook_;
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setLine(address line_) external onlyOwner {
        line = line_;
        emit LineSet(line_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setAgentVerifier(address verifier_) external onlyOwner {
        agentVerifier = verifier_;
    }

    function setRouter(address router_) external onlyOwner {
        router = router_;
    }

    function setHook(address hook_) external onlyOwner {
        hook = hook_;
    }

    function setAgent(uint256 accountId, address agent_) external {
        Account storage a = _account(accountId);
        if (msg.sender != a.owner) revert NotAuthorized();
        a.agent = agent_;
        emit AgentSet(accountId, agent_);
    }

    // ---------------------------------------------------------------------
    // Onboarding and marks
    // ---------------------------------------------------------------------

    function onboard(
        uint256 accountId,
        address stockToken,
        uint256 stockAmt,
        uint256 lpTokenId,
        uint256 lpUnits
    ) external {
        Account storage a = accounts[accountId];
        if (a.nonEmpty) {
            if (a.owner != msg.sender) revert AlreadyOnboarded();
        } else {
            a.owner = msg.sender;
            a.agent = msg.sender;
            a.nonEmpty = true;
        }

        a.stockToken = stockToken;
        a.stockAmt = stockAmt;
        a.lpTokenId = lpTokenId;
        a.lpUnits = lpUnits;
        a.debtWad = 0;
        a.aut = Autonomy({
            capWad: 0,
            capBps: uint16(DEFAULT_CAP_BPS),
            capCountPer12h: MAX_DRAWS_PER_WINDOW,
            spent: 0,
            windowStart: uint64(block.timestamp),
            expiresAt: 0,
            needsStepUp: false
        });

        _refreshMarks(a);

        if (hook != address(0) && lpUnits > 0) {
            IPortfolioMarginHook(hook).lockPosition(lpTokenId, accountId);
            a.lpLocked = true;
        }

        emit Onboarded(accountId, msg.sender);
    }

    function refreshMarks(uint256 accountId) external {
        Account storage a = _account(accountId);
        if (msg.sender != a.owner && msg.sender != a.agent && msg.sender != keeper) {
            revert NotAuthorized();
        }
        _refreshMarks(a);
        if (FEE_ORACLE != address(0)) {
            a.feeCreditFees = IFeeStreamOracle(FEE_ORACLE).feeCreditFor(bytes32(a.lpTokenId));
        }
        emit MarksRefreshed(accountId, a.stockMark, a.lpMark);
    }

    function _refreshMarks(Account storage a) internal {
        (uint256 stockMark, uint64 stockTs) =
            IMarkFeed(MARK_FEED).getMark(bytes32(uint256(uint160(a.stockToken))));
        if (stockTs == 0 || block.timestamp > uint256(stockTs) + MARK_STALE) revert STALE_MARK();
        a.stockMark = stockMark;
        a.stockMarkTs = stockTs;

        if (a.lpUnits > 0) {
            (uint256 lpMark, uint64 lpTs) = IMarkFeed(MARK_FEED).getMark(bytes32(a.lpTokenId));
            if (lpTs == 0 || block.timestamp > uint256(lpTs) + MARK_STALE) revert STALE_MARK();
            a.lpMark = lpMark;
            a.lpMarkTs = lpTs;
        } else {
            a.lpMark = 0;
            a.lpMarkTs = 0;
        }

        if (a.equityRwaAmt > 0 && a.rwaAssetR1 != address(0)) {
            RwaPositionView memory v =
                IRwaCollateralAdapter(RWA_ADAPTER).positionValue(a.rwaAssetR1, a.equityRwaAmt);
            if (v.markTs == 0 || block.timestamp > uint256(v.markTs) + MARK_STALE) {
                revert STALE_MARK();
            }
            a.equityRwaMark = v.mark;
            a.r1MarkTs = v.markTs;
            a.r1TransferRestricted = v.transferRestricted;
        }

        if (a.navAmt > 0 && a.rwaAssetR2 != address(0)) {
            RwaPositionView memory v =
                IRwaCollateralAdapter(RWA_ADAPTER).positionValue(a.rwaAssetR2, a.navAmt);
            a.navPerShareWad = v.navPerShareWad;
            a.accrualPerSecondWad = v.accrualPerSecondWad;
            a.navTs = v.navTs;
            a.gateOpen = v.gateOpen;
            a.rwaSourceTxHash = v.sourceTxHash;
        }
    }

    function setRwaPosition(uint256 accountId, address asset, uint256 amountWad) external {
        Account storage a = _account(accountId);
        if (msg.sender != a.owner) revert NotAuthorized();

        RwaPositionView memory v =
            IRwaCollateralAdapter(RWA_ADAPTER).positionValue(asset, amountWad);

        if (v.class == 1) {
            a.rwaAssetR1 = asset;
            a.equityRwaAmt = amountWad;
            a.equityRwaMark = v.mark;
            a.r1TransferRestricted = v.transferRestricted;
            a.r1MarkTs = v.markTs;
        } else if (v.class == 2) {
            a.rwaAssetR2 = asset;
            a.navAmt = amountWad;
            a.navPerShareWad = v.navPerShareWad;
            a.accrualPerSecondWad = v.accrualPerSecondWad;
            a.navTs = v.navTs;
            a.gateOpen = v.gateOpen;
            a.rwaSourceTxHash = v.sourceTxHash;
            a.lastAccrualTs = uint64(block.timestamp);
            a.navAccrualCredit = 0;
        } else {
            revert NotFound();
        }

        emit RwaPositionSet(accountId, asset, amountWad, v.class);
    }

    // ---------------------------------------------------------------------
    // NAV accrual
    // ---------------------------------------------------------------------

    function pendingNavAccrual(uint256 accountId) public view returns (uint256) {
        Account storage a = accounts[accountId];
        if (a.navAmt == 0 || a.accrualPerSecondWad == 0) return 0;
        uint64 elapsed = uint64(block.timestamp) - a.lastAccrualTs;
        if (elapsed < COUPON_PERIOD) return 0;
        uint64 held = elapsed > ACCRUAL_WINDOW ? ACCRUAL_WINDOW : elapsed;
        uint256 perSecond = Math.mulDiv(a.accrualPerSecondWad, a.navAmt, WAD);
        return perSecond * held;
    }

    function navAccrualCreditView(uint256 accountId) public view returns (uint256) {
        Account storage a = accounts[accountId];
        return a.navAccrualCredit + pendingNavAccrual(accountId);
    }

    function accrueCoupon(uint256 accountId) external {
        Account storage a = _account(accountId);
        if (msg.sender != a.owner && msg.sender != a.agent && msg.sender != keeper) {
            revert NotAuthorized();
        }
        if (a.navTs == 0) revert NotFound();
        if (block.timestamp > uint256(a.navTs) + NAV_STALE) revert NavStale();

        uint64 elapsed = uint64(block.timestamp) - a.lastAccrualTs;
        if (elapsed < COUPON_PERIOD) revert CouponNotMature();

        uint64 held = elapsed > ACCRUAL_WINDOW ? ACCRUAL_WINDOW : elapsed;
        uint256 perSecond = Math.mulDiv(a.accrualPerSecondWad, a.navAmt, WAD);
        uint256 credit = perSecond * held;

        a.navAccrualCredit += credit;
        a.lastAccrualTs = uint64(block.timestamp);

        emit CouponAccrued(accountId, credit, a.rwaSourceTxHash);
    }

    // ---------------------------------------------------------------------
    // Snapshot / pricing
    // ---------------------------------------------------------------------

    function _feeCreditBase(Account storage a, uint256 totalCollateral)
        internal
        view
        returns (uint256)
    {
        return FeeMathLib.combinedCredit(
            a.feeCreditFees, navAccrualCreditViewFor(a), totalCollateral
        );
    }

    function navAccrualCreditViewFor(Account storage a) internal view returns (uint256) {
        if (a.navAmt == 0 || a.accrualPerSecondWad == 0) return a.navAccrualCredit;
        uint64 elapsed = uint64(block.timestamp) - a.lastAccrualTs;
        if (elapsed < COUPON_PERIOD) return a.navAccrualCredit;
        uint64 held = elapsed > ACCRUAL_WINDOW ? ACCRUAL_WINDOW : elapsed;
        uint256 perSecond = Math.mulDiv(a.accrualPerSecondWad, a.navAmt, WAD);
        return a.navAccrualCredit + perSecond * held;
    }

    function _snapshot(uint256 accountId)
        internal
        view
        returns (SpanMathLib.PortfolioResult memory r)
    {
        Account storage a = _account(accountId);

        uint256 stockUsd = a.stockAmt.mulWad(a.stockMark);
        uint256 lpUsd = a.lpUnits.mulWad(a.lpMark);
        uint256 equityUsd = a.equityRwaAmt.mulWad(a.equityRwaMark);
        uint256 navUsd = a.navAmt.mulWad(a.navPerShareWad);
        uint256 totalCollateral = stockUsd + lpUsd + equityUsd + navUsd;

        uint256 dailyCoupon = Math.mulDiv(a.accrualPerSecondWad, a.navAmt, WAD) * 86400;
        bool navFresh = a.navTs != 0 && block.timestamp <= uint256(a.navTs) + NAV_STALE;
        bool gateOpen = a.gateOpen && navFresh;

        r = SpanMathLib.portfolioSnapshotUsd(
            stockUsd,
            lpUsd,
            equityUsd,
            navUsd,
            a.feeCreditFees,
            navAccrualCreditViewFor(a),
            dailyCoupon,
            a.debtWad,
            a.r1TransferRestricted,
            gateOpen,
            DAILY_CAP_PER_INVESTOR
        );

        r.feeCreditBase = FeeMathLib.combinedCredit(
            a.feeCreditFees, navAccrualCreditViewFor(a), totalCollateral
        );
    }

    function computeBp(uint256 accountId) external view returns (uint256) {
        return _snapshot(accountId).bp;
    }

    function marginBreakdown(uint256 accountId)
        external
        view
        returns (uint256 bp, uint256 unwindableNow, uint256 earningLocked, uint256 health)
    {
        SpanMathLib.PortfolioResult memory r = _snapshot(accountId);
        return (r.bp, r.unwindableNow, r.earningLocked, r.health);
    }

    function stressGrid(uint256 accountId) external view returns (uint256[16] memory) {
        return _snapshot(accountId).scenarioLosses;
    }

    function feeCreditBaseOf(uint256 accountId) external view returns (uint256) {
        return _snapshot(accountId).feeCreditBase;
    }

    function totalCollateralUsd(uint256 accountId) external view returns (uint256) {
        Account storage a = accounts[accountId];
        return a.stockAmt.mulWad(a.stockMark) + a.lpUnits.mulWad(a.lpMark)
            + a.equityRwaAmt.mulWad(a.equityRwaMark) + a.navAmt.mulWad(a.navPerShareWad);
    }

    // ---------------------------------------------------------------------
    // Credit line
    // ---------------------------------------------------------------------

    function draw(uint256 accountId, uint256 amtWad) external {
        Account storage a = _account(accountId);
        if (msg.sender != a.owner && msg.sender != line) revert NotAuthorized();
        _draw(a, accountId, amtWad);
    }

    function agentDraw(uint256 accountId, uint256 amtWad) external {
        Account storage a = _account(accountId);
        if (msg.sender != a.agent) revert NotAuthorized();

        if (block.timestamp >= uint256(a.aut.windowStart) + DRAW_WINDOW) {
            a.aut.windowStart = uint64(block.timestamp);
            a.aut.spent = 0;
        }
        if (a.aut.spent >= a.aut.capCountPer12h) revert CapExceededBlock();

        SpanMathLib.PortfolioResult memory r = _snapshot(accountId);
        uint256 cap = Math.mulDiv(r.bp, a.aut.capBps, 10_000);
        if (amtWad > cap) revert CapExceededBlock();

        a.aut.spent += 1;
        _draw(a, accountId, amtWad);
    }

    function _draw(Account storage a, uint256 accountId, uint256 amtWad) internal {
        if (amtWad == 0) revert NotFound();
        SpanMathLib.PortfolioResult memory r = _snapshot(accountId);
        if (a.debtWad + amtWad > r.bp) revert DebtExceedsBp();
        a.debtWad += amtWad;
        emit Drew(accountId, amtWad);
    }

    function repay(uint256 accountId, uint256 amtWad) external {
        Account storage a = _account(accountId);
        if (
            msg.sender != a.owner && msg.sender != a.agent && msg.sender != a.unwinder
                && msg.sender != line
        ) revert NotAuthorized();
        uint256 amount = amtWad > a.debtWad ? a.debtWad : amtWad;
        a.debtWad -= amount;
        emit Repaid(accountId, amount);
    }

    function debtOf(uint256 accountId) external view returns (uint256) {
        return accounts[accountId].debtWad;
    }

    function ownerOf(uint256 accountId) external view returns (address) {
        return accounts[accountId].owner;
    }

    // ---------------------------------------------------------------------
    // Human cosign / World Agent Pass
    // ---------------------------------------------------------------------

    function stepUp(uint256 accountId, bytes32 proofHash, uint8 newCapTier) external {
        if (msg.sender != agentVerifier) revert NotAuthorized();
        Account storage a = _account(accountId);
        if (proofHash == bytes32(0) || consumedProofs[proofHash]) revert NotHumanApproved();
        consumedProofs[proofHash] = true;

        uint16 bps = newCapTier == 0 ? 200 : newCapTier == 1 ? 500 : 1000;
        a.aut.capBps = bps;
        a.aut.expiresAt = uint64(block.timestamp) + STEP_UP_EXPIRY;
        a.aut.needsStepUp = false;
        emit SteppedUp(accountId, bps, a.aut.expiresAt);
    }

    function acceptLockedRisk(uint256 accountId, bytes32 proofHash) external {
        if (msg.sender != agentVerifier) revert NotAuthorized();
        Account storage a = _account(accountId);
        if (proofHash == bytes32(0) || consumedProofs[proofHash]) revert NotHumanApproved();
        consumedProofs[proofHash] = true;
        a.lockedRiskAccepted = true;
        a.lockedRiskExpiry = uint64(block.timestamp) + LOCKED_RISK_EXPIRY;
        emit LockedRiskAccepted(accountId, a.lockedRiskExpiry);
    }

    function registerUnwinder(uint256 accountId, address who) external {
        Account storage a = _account(accountId);
        if (msg.sender != a.owner) revert NotAuthorized();
        a.unwinder = who;
        a.unwinderOk = true;
        emit UnwinderSet(accountId, who);
    }

    function setGateState(uint256 accountId, bool open) external {
        if (msg.sender != NAV_ORACLE && msg.sender != keeper) revert NotAuthorized();
        Account storage a = _account(accountId);
        a.gateOpen = open;
        emit GateShut(accountId, open);

        SpanMathLib.PortfolioResult memory r = _snapshot(accountId);
        emit SegregationChanged(r.unwindableNow, r.earningLocked);
    }

    // ---------------------------------------------------------------------
    // Atomic unwind
    // ---------------------------------------------------------------------

    function unwind(uint256 accountId) external {
        Account storage a = accounts[accountId];
        _onlyUnwinder(a);
        uint256 debtBefore = _unwindEligible(accountId);

        uint256 received = ISpanRouter(router).spanNetUnwind(accountId);
        if (received < debtBefore) revert BadDebtProjection();
        _settle(a, accountId, debtBefore);
    }

    /// @notice Fallback Mode (G-G1 failed): identical settlement in plain EVM.
    function unwindNettedFallback(uint256 accountId, uint256 usdcReceived) external {
        Account storage a = accounts[accountId];
        _onlyUnwinder(a);
        uint256 debtBefore = _unwindEligible(accountId);
        if (usdcReceived < debtBefore) revert BadDebtProjection();
        _settle(a, accountId, debtBefore);
    }

    function _onlyUnwinder(Account storage a) internal view {
        if (!a.nonEmpty) revert NotFound();
        if (!a.unwinderOk || msg.sender != a.unwinder) revert NotAuthorized();
    }

    function _unwindEligible(uint256 accountId) internal view returns (uint256 debtBefore) {
        Account storage a = accounts[accountId];
        SpanMathLib.PortfolioResult memory r = _snapshot(accountId);

        bool unhealthy = r.health < MAINT;
        bool overLine = a.debtWad > r.unwindableNow.mulWad(LTV_MAX);
        if (!unhealthy && !overLine) revert UnwindNotEligible();

        if (a.debtWad > r.unwindableNow) {
            bool accepted = a.lockedRiskAccepted && block.timestamp <= a.lockedRiskExpiry;
            if (!accepted) revert InsufficientUnwindable();
        }
        return a.debtWad;
    }

    function _settle(Account storage a, uint256 accountId, uint256 repaid) internal {
        a.debtWad = 0;
        a.stockAmt = 0;
        a.lpUnits = 0;
        a.equityRwaAmt = 0;
        a.navAmt = 0;
        a.navAccrualCredit = 0;
        a.lockedRiskAccepted = false;

        if (a.lpLocked && hook != address(0)) {
            IPortfolioMarginHook(hook).unlockPosition(a.lpTokenId);
        }
        a.lpLocked = false;

        emit Unwound(accountId, repaid, 0);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function stateOf(uint256 accountId) external view returns (State) {
        Account storage a = accounts[accountId];
        if (!a.nonEmpty) return State.EMPTY;
        if (a.debtWad == 0) return State.PRICED;
        SpanMathLib.PortfolioResult memory r = _snapshot(accountId);
        if (r.health < MAINT) return State.STRESSED;
        if (a.debtWad > r.unwindableNow.mulWad(LTV_MAX)) return State.STRESSED;
        return State.ACTIVE;
    }

    function healthOf(uint256 accountId) external view returns (uint256) {
        return _snapshot(accountId).health;
    }

    function getAccount(uint256 accountId) external view returns (Account memory) {
        return accounts[accountId];
    }

    function _account(uint256 accountId) internal view returns (Account storage a) {
        a = accounts[accountId];
        if (!a.nonEmpty) revert NotFound();
    }
}
