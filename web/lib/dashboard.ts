export type DeskTab = "onboard" | "desk" | "stress" | "agent";

export interface CollateralLeg {
  id: "equity" | "lp" | "treasury";
  label: string;
  detail: string;
  valueUsd: number;
  haircut: number;
  status: string;
  liquidatable: boolean;
}

export interface Scenario {
  id: string;
  shock: number;
  vol: number;
  lossUsd: number;
}

export interface DeskSnapshot {
  debtUsd: number;
  borrowingPowerUsd: number;
  health: number;
  initialMarginUsd: number;
  unwindableNowUsd: number;
  earningLockedUsd: number;
  totalHaircutUsd: number;
  drawCapUsd: number;
  requiresStepUp: boolean;
  gateOpen: boolean;
  couponPerDayUsd: number;
  legs: CollateralLeg[];
  scenarios: Scenario[];
}

const shocks = [-0.2, -0.1, -0.05, -0.02, 0.02, 0.05, 0.1, 0.2];
const vols = [1, 1.5];

const roundMoney = (value: number) => Math.round(value * 100) / 100;

export const formatUsd = (value: number, fractionDigits = 2) =>
  new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: fractionDigits,
    maximumFractionDigits: fractionDigits,
  }).format(value);

export const formatPercent = (value: number) => `${(value * 100).toFixed(0)}%`;

export function buildSnapshot(gateOpen: boolean, debtUsd = 1_930): DeskSnapshot {
  const legs: CollateralLeg[] = [
    {
      id: "equity",
      label: "Tokenized equity",
      detail: "Base mark · transfer path pending verification",
      valueUsd: 1_900,
      haircut: 0.75,
      status: "mark only",
      liquidatable: true,
    },
    {
      id: "lp",
      label: "Locked v4 LP",
      detail: "Fee stream · 7-day oracle window",
      valueUsd: 1_250,
      haircut: 0.7,
      status: "hook locked",
      liquidatable: true,
    },
    {
      id: "treasury",
      label: "Treasury NAV signal",
      detail: gateOpen ? "redemption gate open" : "gate shut · earning but locked",
      valueUsd: 1_600,
      haircut: 0.85,
      status: gateOpen ? "gate open" : "earning but locked",
      liquidatable: gateOpen,
    },
  ];

  const totalHaircutUsd = roundMoney(
    legs.reduce((total, leg) => total + leg.valueUsd * leg.haircut, 0),
  );
  const unwindableNowUsd = roundMoney(
    legs
      .filter((leg) => leg.liquidatable)
      .reduce((total, leg) => total + leg.valueUsd * leg.haircut, 0),
  );
  const earningLockedUsd = roundMoney(totalHaircutUsd - unwindableNowUsd);
  const initialMarginUsd = 264;
  const stressedCollateralUsd = Math.max(0, totalHaircutUsd - initialMarginUsd);
  const borrowingPowerUsd = roundMoney(stressedCollateralUsd * 0.8);

  const scenarios = shocks.flatMap((shock) =>
    vols.map((vol) => {
      const downside = Math.max(0, -shock * vol);
      const stockLoss = 1_900 * downside;
      const lpLoss = 1_250 * (0.8 * Math.abs(shock * vol) + 0.05 * (shock * vol) ** 2);
      const r1Loss = 1_900 * 0.2 * 1.5 * vol;
      const r2Loss = 1_600 * 0.015;
      return {
        id: `${Math.round(shock * 100)}-${vol}`,
        shock,
        vol,
        lossUsd: roundMoney(stockLoss + lpLoss + r1Loss + r2Loss),
      };
    }),
  );

  return {
    debtUsd,
    borrowingPowerUsd,
    health: roundMoney(stressedCollateralUsd / Math.max(debtUsd, 0.000001)),
    initialMarginUsd,
    unwindableNowUsd,
    earningLockedUsd,
    totalHaircutUsd,
    drawCapUsd: roundMoney(borrowingPowerUsd * 0.02),
    requiresStepUp: debtUsd > unwindableNowUsd * 0.8,
    gateOpen,
    couponPerDayUsd: 0,
    legs,
    scenarios,
  };
}

export const crashReplays = [
  { id: "aug-2024", label: "Aug 2024", shock: "−14.8%", isolated: "$812.40", cross: "$1,146.10" },
  { id: "feb-2025", label: "Feb 2025", shock: "−9.6%", isolated: "$1,048.70", cross: "$1,321.90" },
  { id: "oct-2026", label: "Oct 2026", shock: "−18.2%", isolated: "$684.30", cross: "$1,008.60" },
] as const;

export const navigation: Array<{ id: DeskTab; label: string; kicker: string }> = [
  { id: "onboard", label: "Onboard", kicker: "01" },
  { id: "desk", label: "Credit Desk", kicker: "02" },
  { id: "stress", label: "Stress", kicker: "03" },
  { id: "agent", label: "Agent", kicker: "04" },
];
