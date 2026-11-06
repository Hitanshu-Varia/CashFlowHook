"use client";

import { useState, type ReactNode } from "react";
import {
  buildSnapshot,
  crashReplays,
  formatPercent,
  formatUsd,
  navigation,
  type DeskSnapshot,
  type DeskTab,
  type Scenario,
} from "../lib/dashboard";

type StepUpStatus = "idle" | "denied" | "approved";

function SectionTitle({ eyebrow, title, action }: { eyebrow: string; title: string; action?: ReactNode }) {
  return <div className="section-title"><div><span className="eyebrow">{eyebrow}</span><h2>{title}</h2></div>{action}</div>;
}

function Metric({ label, value, detail, tone = "default" }: { label: string; value: string; detail: string; tone?: "default" | "amber" | "mint" }) {
  return <article className={`metric metric-${tone}`}><span className="eyebrow">{label}</span><strong>{value}</strong><small>{detail}</small></article>;
}

function SnapshotBadge() {
  return <p className="snapshot-badge"><span aria-hidden="true">●</span> Deterministic demo snapshot · connect the local fork for runtime contract reads</p>;
}

function CollateralMix({ snapshot }: { snapshot: DeskSnapshot }) {
  return <section className="panel collateral-panel">
    <SectionTitle eyebrow="Collateral mix" title="What can unwind now" />
    <div className="mix-bar" aria-label="Collateral mix">
      {snapshot.legs.map((leg) => <div className={`mix-segment ${leg.id} ${leg.liquidatable ? "" : "locked"}`} key={leg.id} style={{ width: `${(leg.valueUsd * leg.haircut / snapshot.totalHaircutUsd) * 100}%` }} />)}
    </div>
    <div className="mix-legend">
      {snapshot.legs.map((leg) => <div className="mix-legend-row" key={leg.id}><span className={`dot ${leg.id}`} /><span>{leg.label}</span><strong>{formatUsd(leg.valueUsd * leg.haircut)}</strong>{!leg.liquidatable && <em>earning but locked</em>}</div>)}
    </div>
    <div className="split-summary"><div><span>Unwindable now</span><strong>{formatUsd(snapshot.unwindableNowUsd)}</strong></div><div className={snapshot.earningLockedUsd > 0 ? "locked-summary" : ""}><span>Earning but locked</span><strong>{formatUsd(snapshot.earningLockedUsd)}</strong></div></div>
  </section>;
}

function Positions({ snapshot }: { snapshot: DeskSnapshot }) {
  return <section className="panel positions-panel">
    <SectionTitle eyebrow="Margin book" title="Positions & cashflow" />
    <div className="positions-list">
      {snapshot.legs.map((leg) => <article className="position-row" key={leg.id}>
        <span className={`position-icon ${leg.id}`} aria-hidden="true">{leg.id === "lp" ? "≈" : leg.id === "treasury" ? "▣" : "↗"}</span>
        <div className="position-copy"><strong>{leg.label}</strong><span>{leg.detail}</span></div>
        <div className="position-value"><strong>{formatUsd(leg.valueUsd)}</strong><span>{formatPercent(leg.haircut)} haircut</span></div>
        <span className={`status-pill ${leg.liquidatable ? "" : "warning"}`}>{leg.status}</span>
      </article>)}
    </div>
    <div className="formula-block"><span className="eyebrow">StrategyScore</span><code>min(100, round(100·(0.5·(1 − min(1, σ/μ)) + 0.3·(1 − maxWeeklyDDfrac) + 0.2·min(1, ageDays/7))))</code><p>Distinct third-party takers: 12 · borrower excluded · seven-day record</p></div>
  </section>;
}

function ScenarioGrid({ snapshot, selected, onSelect }: { snapshot: DeskSnapshot; selected: Scenario; onSelect: (scenario: Scenario) => void }) {
  return <div className="scenario-layout">
    <div className="scenario-grid" role="list" aria-label="Sixteen SPAN scenarios">
      {snapshot.scenarios.map((scenario) => <button aria-pressed={selected.id === scenario.id} className={`scenario ${scenario.shock < 0 ? "downside" : "upside"} ${selected.id === scenario.id ? "selected" : ""}`} key={scenario.id} onClick={() => onSelect(scenario)} type="button"><span>{scenario.shock > 0 ? "+" : ""}{(scenario.shock * 100).toFixed(0)}%</span><small>{scenario.vol.toFixed(1)}× vol</small><strong>{formatUsd(scenario.lossUsd, 0)}</strong></button>)}
    </div>
    <aside className="scenario-detail"><span className="eyebrow">Selected input</span><h3>{selected.shock > 0 ? "+" : ""}{(selected.shock * 100).toFixed(0)}% shock · {selected.vol.toFixed(1)}× vol</h3><dl><div><dt>Grid loss</dt><dd>{formatUsd(selected.lossUsd)}</dd></div><div><dt>R1 gap premium</dt><dd>0.50×</dd></div><div><dt>R2 exit term</dt><dd>Included</dd></div></dl><p>Inputs are fixture data until a fork-backed margin read is configured.</p></aside>
  </div>;
}

export default function CreditDesk() {
  const [tab, setTab] = useState<DeskTab>("desk");
  const [connected, setConnected] = useState(false);
  const [unwinderGranted, setUnwinderGranted] = useState(false);
  const [gateOpen, setGateOpen] = useState(true);
  const [debtUsd, setDebtUsd] = useState(1_930);
  const [stepUp, setStepUp] = useState<StepUpStatus>("idle");
  const [notice, setNotice] = useState("Ready for a local-fork connection.");
  const [receiptCount, setReceiptCount] = useState(1);
  const snapshot = buildSnapshot(gateOpen, debtUsd);
  const [selectedScenario, setSelectedScenario] = useState(snapshot.scenarios[0]);
  const [replay, setReplay] = useState<(typeof crashReplays)[number]>(crashReplays[0]);

  const closeGate = () => { setGateOpen(false); setStepUp("idle"); setNotice("Gate shut simulated: treasury collateral is now earning but locked. Autonomy has been capped."); };
  const reopenGate = () => { setGateOpen(true); setNotice("Gate-open simulation restored. Connect the fork to observe an on-chain SegregationChanged event."); };
  const requestStepUp = () => { setStepUp("denied"); setNotice("Denied path shown first: no cap changed and no protected action occurred."); };
  const completeStepUp = () => { setStepUp("approved"); setNotice("Preview only: a real World result must be validated server-side before it reaches AgentPassVerifier."); };
  const requestDraw = () => {
    if (snapshot.requiresStepUp && stepUp !== "approved") { setNotice("This draw remains blocked until a verified human step-up is posted on-chain."); return; }
    if (debtUsd + snapshot.drawCapUsd > snapshot.borrowingPowerUsd) { setNotice("Draw blocked: the request would exceed borrowing power."); return; }
    setDebtUsd((current) => Math.round((current + snapshot.drawCapUsd) * 100) / 100);
    setReceiptCount((count) => count + 1);
    setNotice(`Preview draw recorded for ${formatUsd(snapshot.drawCapUsd)}. No Aqua transfer was submitted from this screen.`);
  };

  return <main className="shell">
    <aside className="sidebar">
      <div className="brand"><span className="brand-mark" aria-hidden="true">C</span><div><strong>CashflowHook</strong><span>credit desk / v3</span></div></div>
      <nav aria-label="Credit Desk sections">{navigation.map((item) => <button className={`nav-item ${tab === item.id ? "active" : ""}`} key={item.id} onClick={() => setTab(item.id)} type="button"><span>{item.kicker}</span>{item.label}</button>)}</nav>
      <div className="sidebar-foot"><span className="eyebrow">Settlement</span><strong>Aqua virtual balance</strong><p>Non-custodial — assets remain in the account wallet.</p></div>
    </aside>

    <div className="workspace">
      <header className="topbar"><div><span className="eyebrow">Base fork / account 01</span><h1>{navigation.find((item) => item.id === tab)?.label}</h1></div><div className="topbar-actions"><span className={`network-status ${gateOpen ? "open" : "shut"}`}>{gateOpen ? "NAV gate open" : "NAV gate shut"}</span><button className="quiet-button" onClick={gateOpen ? closeGate : reopenGate} type="button">{gateOpen ? "Simulate gate shut" : "Restore gate"}</button></div></header>
      <div aria-live="polite" className={`notice ${gateOpen ? "" : "alert"}`}><span aria-hidden="true">{gateOpen ? "·" : "!"}</span>{notice}</div>

      {tab === "onboard" && <section className="onboard-view">
        <SnapshotBadge />
        <div className="onboard-hero"><span className="eyebrow">Account setup</span><h2>A human-cosigned credit line for an agent.</h2><p>Set up the local demonstration account, then connect the fork adapters for contract-backed values.</p></div>
        <div className="onboard-steps">
          <article className={connected ? "complete" : ""}><span>01</span><div><strong>Connect account</strong><p>Local demonstration wallet only.</p></div><button onClick={() => { setConnected(true); setNotice("Demo account connected. No wallet extension was requested."); }} type="button">{connected ? "Connected" : "Connect"}</button></article>
          <article className={connected ? "" : "disabled"}><span>02</span><div><strong>Review scope</strong><p>2% per draw · 3 draws / 12h.</p></div><button disabled={!connected} onClick={() => setNotice("Scope reviewed: autonomous draws remain capped until a server-validated World step-up.")} type="button">Review</button></article>
          <article className={unwinderGranted ? "complete" : ""}><span>03</span><div><strong>Grant unwinder</strong><p>One approved router can execute a stressed unwind.</p></div><button disabled={!connected} onClick={() => { setUnwinderGranted(true); setNotice("Preview grant set. A real grant is owner-signed on the connected fork."); }} type="button">{unwinderGranted ? "Granted" : "Grant"}</button></article>
        </div>
        <div className="onboard-note"><strong>World protection:</strong> browser UI never authorizes a cap raise; the backend validates the proof before calling the on-chain verifier.</div>
      </section>}

      {tab === "desk" && <section className="desk-view">
        <SnapshotBadge />
        <div className="metric-grid"><Metric detail="computed from the 16-scenario grid" label="Borrowing power" value={formatUsd(snapshot.borrowingPowerUsd)} tone="mint" /><Metric detail="Aqua virtual balance" label="Debt" value={formatUsd(snapshot.debtUsd)} /><Metric detail="maintenance threshold: 0.85×" label="Health" value={`${snapshot.health.toFixed(2)}×`} tone={snapshot.health < 0.85 ? "amber" : "mint"} /><Metric detail="maximum autonomous amount" label="Next draw cap" value={formatUsd(snapshot.drawCapUsd)} /></div>
        <div className="coupon-ticker"><span aria-hidden="true">↗</span><div><strong>{formatUsd(snapshot.couponPerDayUsd)} borrowing power today</strong><span>OUSG/USDY NAV accrual is disabled until G-RWA-1 is verified.</span></div><em>marks-only fallback</em></div>
        <div className="desk-grid"><Positions snapshot={snapshot} /><div className="side-stack"><CollateralMix snapshot={snapshot} /><section className="panel draw-panel"><SectionTitle eyebrow="Autonomy" title="Agent draw policy" /><div className="policy-meter"><span style={{ width: `${Math.min(100, (snapshot.debtUsd / snapshot.borrowingPowerUsd) * 100)}%` }} /></div><p><strong>2%</strong> of borrowing power per draw · <strong>3</strong> draws / 12 h</p>{snapshot.requiresStepUp && stepUp !== "approved" ? <button className="primary-button" onClick={requestStepUp} type="button">Request human step-up</button> : <button className="primary-button" onClick={requestDraw} type="button">Preview agent draw · {formatUsd(snapshot.drawCapUsd)}</button>}</section></div></div>
        <section className="panel receipts-panel"><SectionTitle eyebrow="Receipts registry" title="Agent spend history" action={<span className="status-pill">{receiptCount} preview records</span>} /><div className="receipt-row"><span>09:42:11</span><strong>x402 bill receipt</strong><span>Endpoint not configured</span><em>preview</em></div><div className="receipt-row"><span>09:38:05</span><strong>Autonomous draw request</strong><span>{formatUsd(snapshot.drawCapUsd)} maximum</span><em>policy checked</em></div></section>
      </section>}

      {tab === "stress" && <section className="stress-view"><SnapshotBadge /><section className="panel"><SectionTitle eyebrow="SPAN grid" title="16 scenarios · 8 shocks × 2 vol states" action={<span className="status-pill">IM {formatUsd(snapshot.initialMarginUsd)}</span>} /><ScenarioGrid onSelect={setSelectedScenario} selected={selectedScenario} snapshot={snapshot} /></section><section className="panel replay-panel"><SectionTitle eyebrow="Crash timeline" title="Isolated comparison" /><div className="replay-options">{crashReplays.map((item) => <button className={replay.id === item.id ? "selected" : ""} key={item.id} onClick={() => setReplay(item)} type="button">{item.label}<span>{item.shock}</span></button>)}</div><div className="replay-result"><div><span>Isolated account</span><strong>{replay.isolated}</strong><small>remaining collateral</small></div><div><span>Cross-margined book</span><strong>{replay.cross}</strong><small>same inputs, netted legs</small></div><p>Replay values are pinned demo fixtures. Connect archive data before making historical claims.</p></div></section></section>}

      {tab === "agent" && <section className="agent-view"><SnapshotBadge /><div className="agent-grid"><section className="panel policy-log"><SectionTitle eyebrow="Policy log" title="Deterministic decisions" /><ol><li><span>09:42:11</span><div><strong>{snapshot.requiresStepUp ? "Autonomy paused" : "Draw budget available"}</strong><p>{snapshot.requiresStepUp ? "Debt exceeds 80% of liquidatable backing after the gate event." : `Next autonomous draw is capped at ${formatUsd(snapshot.drawCapUsd)}.`}</p></div></li><li><span>09:41:58</span><div><strong>NAV feed status</strong><p>Coupon accrual is zero while the verified mainnet NAV adapter remains unconfigured.</p></div></li><li><span>09:40:02</span><div><strong>Receipt guard</strong><p>External x402 payment is not enabled; no network request has been made.</p></div></li></ol></section><section className="panel stepup-panel"><SectionTitle eyebrow="World Agent Pass" title="Human step-up" />{stepUp === "idle" && <><p>A verified human may raise the cap or explicitly accept locked-liquidity risk. This browser can only preview the journey.</p><button className="primary-button" onClick={requestStepUp} type="button">Show denied path</button></>}{stepUp === "denied" && <><span className="denied-label">DENIED · proof expired</span><p>No cap changed. No draw or unwind authorisation was produced.</p><button className="primary-button" onClick={completeStepUp} type="button">Preview verified completion</button></>}{stepUp === "approved" && <><span className="approved-label">PREVIEW COMPLETE</span><p>For a live action, the backend validates the proof and submits it to AgentPassVerifier. Client state alone has no authority.</p><button className="quiet-button" onClick={() => setStepUp("idle")} type="button">Reset preview</button></>}</section></div><section className="panel limits-strip"><strong>Demo posture</strong><span>Trusted-signature oracles, mocked World proof flow, fork-based Aqua path, and unverified RWA feeds must remain disclosed until their respective gates are signed.</span></section></section>}
    </div>
  </main>;
}
