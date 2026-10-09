// Notification emails (Blueprint 13): Paper "Emails — Transactional v2"
// M01–M14, M16–M18 (approved 2026-10-09), T01 and A10–A12, on the shared
// layout. Money emails show the exact amount and the public reference only
// (P-06): never balances, account digits, bank details, reasons or evidence.
// Buttons open the in-app path carried by the event, from an allow-list.

import { renderLayout, type RootPose, type StatusTone, supportEmail } from "./layout.ts";
import {
  appOrigin,
  oneLine,
  onlyParams,
  param,
  type Params,
  type RenderContext,
  type RenderedEmail,
  TemplateError,
} from "./params.ts";

/** Profile names: first + last are up to 80 characters each (identity.profiles). */
const nameMax = 200;

const symbols: Readonly<Record<string, string>> = { NGN: "₦", USD: "$" };

/** "₦48,000.00" from the exact decimal string; never through a float. */
export function formatMoney(amount: string, currency: string): string {
  const symbol = symbols[currency];
  const match = /^(\d{1,30})\.(\d{2})$/.exec(amount);
  if (!symbol || !match) throw new TemplateError("template.param_invalid");
  const whole = (match[1] ?? "").replace(/^0+(?=\d)/, "").replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${symbol}${whole}.${match[2]}`;
}

const pathPattern =
  /^\/app(\/[a-z][a-z-]*)*(\?withdrawal=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$/;

function optional(params: Params, name: string, max = 200): string | undefined {
  return params[name] === undefined ? undefined : param(params, name, max);
}

function reference(params: Params): string {
  const value = param(params, "reference", 20);
  if (!/^[A-Z]{3}-[0-9A-Z]{4}-[0-9A-Z]{4}$/.test(value)) {
    throw new TemplateError("template.param_invalid");
  }
  return value;
}

function amountOf(params: Params, amount = "amount", currency = "currency"): string {
  return formatMoney(param(params, amount, 40), param(params, currency, 3));
}

const roleLabels: Readonly<Record<string, string>> = {
  member: "Member",
  team_leader: "Team Leader",
  director: "Director",
  world_team_member: "World Team",
  president_team_member: "President Team",
};

function role(params: Params): string {
  const label = roleLabels[param(params, "role", 40)];
  if (!label) throw new TemplateError("template.param_invalid");
  return label;
}

const subjects = {
  payout: { label: "payout", chip: "Payout", what: "receipt" },
  conversion: { label: "conversion", chip: "Conversion", what: "receipt" },
  adjustment: { label: "adjustment", chip: "Adjustment", what: "evidence" },
  returned_funds: { label: "return", chip: "Returned funds", what: "proof" },
} as const;

function subjectOf(params: Params): (typeof subjects)[keyof typeof subjects] {
  const value = param(params, "subject", 20);
  if (!(value in subjects)) throw new TemplateError("template.param_invalid");
  return subjects[value as keyof typeof subjects];
}

interface Spec {
  /** Network name for the sender row, or the Elivate mark (A10). */
  readonly network: string | null;
  readonly subject: string;
  readonly chip: string;
  readonly status?: { readonly label: string; readonly tone: StatusTone };
  readonly display: string;
  readonly reference?: string;
  readonly root: RootPose;
  readonly headline: string;
  readonly line: string;
  readonly button: string;
}

function build(spec: Spec, params: Params, context: RenderContext): RenderedEmail {
  const origin = appOrigin(context);
  const path = param(params, "path", 200);
  if (!pathPattern.test(path)) throw new TemplateError("template.link_missing");
  const url = `${origin}${path}`;
  const html = renderLayout({
    brand: spec.network === null ? "elivate" : { network: spec.network },
    chip: spec.chip,
    ...(spec.status ? { status: spec.status } : {}),
    display: spec.display,
    ...(spec.reference ? { reference: spec.reference } : {}),
    root: spec.root,
    headline: spec.headline,
    line: spec.line,
    button: { label: spec.button, url },
    assetBase: `${origin}/email`,
  });
  const text = [
    spec.headline,
    "",
    spec.line,
    "",
    ...(spec.reference ? [spec.reference, ""] : []),
    `${spec.button}: ${url}`,
    "",
    `Questions? ${supportEmail}`,
    spec.network === null ? "Wallet by Elivate" : `${spec.network} · Powered by Elivate Wallet`,
  ].join("\n");
  return { subject: oneLine(spec.subject, 200), html, text };
}

type Renderer = (params: Params, context: RenderContext) => RenderedEmail;

const money = ["network", "amount", "currency", "reference", "path"] as const;

/** A money email whose hero is the amount and the reference (most M-series). */
function simple(
  copy: Omit<Spec, "network" | "display" | "reference">,
): Renderer {
  return (params, context) => {
    onlyParams(params, money);
    return build(
      {
        ...copy,
        network: param(params, "network", 100),
        display: amountOf(params),
        reference: reference(params),
      },
      params,
      context,
    );
  };
}

export const notificationRenderers: Readonly<Record<string, Renderer>> = {
  // M01
  "money.income_posted": simple({
    subject: "Income is in your pockets",
    chip: "Income",
    status: { label: "Posted", tone: "success" },
    root: "income-posted",
    headline: "Income is in your pockets.",
    line: "It’s already split across your pockets.",
    button: "View income",
  }),
  // M02
  "money.withdrawal_submitted": simple({
    subject: "Withdrawal requested",
    chip: "Withdrawal",
    status: { label: "Submitted", tone: "muted" },
    root: "withdrawal-submitted",
    headline: "Withdrawal requested.",
    line: "We’ll email you when your Team Leader reviews it.",
    button: "View request",
  }),
  // M03
  "money.withdrawal_awaiting_approval": (params, context) => {
    onlyParams(params, [...money, "member", "office"]);
    const member = param(params, "member", nameMax);
    return build(
      {
        network: param(params, "network", 100),
        subject: "A withdrawal needs your approval",
        chip: "Needs approval",
        display: amountOf(params),
        reference: `${reference(params)} · ${member}`,
        root: "withdrawal-awaiting",
        headline: "A withdrawal needs your approval.",
        line: `${member} requested a payout from ${param(params, "office", 100)}.`,
        button: "Review request",
      },
      params,
      context,
    );
  },
  // M04
  "money.withdrawal_approved": simple({
    subject: "Your withdrawal is approved",
    chip: "Withdrawal",
    status: { label: "Approved", tone: "success" },
    root: "withdrawal-approved",
    headline: "Your withdrawal is approved.",
    line: "Payout is next. We’ll email you when it’s paid.",
    button: "View withdrawal",
  }),
  // M05
  "money.withdrawal_completed": (params, context) => {
    onlyParams(params, [...money, "firstName"]);
    const first = optional(params, "firstName", 80);
    return build(
      {
        network: param(params, "network", 100),
        subject: "Your withdrawal is paid",
        chip: "Withdrawal",
        status: { label: "Completed", tone: "success" },
        display: amountOf(params),
        reference: reference(params),
        root: "withdrawal-completed",
        headline: "Your withdrawal is paid.",
        line: first
          ? `Hi ${first}, the payout to your bank account is confirmed.`
          : "The payout to your bank account is confirmed.",
        button: "View withdrawal",
      },
      params,
      context,
    );
  },
  // M06
  "money.withdrawal_not_approved": simple({
    subject: "Your withdrawal wasn’t approved",
    chip: "Withdrawal",
    status: { label: "Not approved", tone: "danger" },
    root: "withdrawal-rejected",
    headline: "Your withdrawal wasn’t approved.",
    line: "The amount is back in your pocket. See why in Wallet.",
    button: "View details",
  }),
  // M07
  "money.withdrawal_cancelled": simple({
    subject: "Withdrawal cancelled",
    chip: "Withdrawal",
    status: { label: "Cancelled", tone: "muted" },
    root: "withdrawal-cancelled",
    headline: "Withdrawal cancelled.",
    line: "The amount is back in your pocket.",
    button: "View pocket",
  }),
  // M08
  "money.payout_correction_required": simple({
    subject: "A payout record needs a fix",
    chip: "Payout",
    status: { label: "Needs correction", tone: "warning" },
    root: "payout-correction",
    headline: "A payout record needs a fix.",
    line: "Upload a corrected receipt to finish this payout.",
    button: "Fix payout record",
  }),
  // M09 (payouts, and conversions/adjustments/returns with their own noun)
  "money.evidence_review_assigned": (params, context) => {
    onlyParams(params, [...money, "subject"]);
    const subject = subjectOf(params);
    const headline = subject.label === "return"
      ? "Returned funds need your review."
      : `${subject.label === "adjustment" ? "An" : "A"} ${subject.label} needs your review.`;
    return build(
      {
        network: param(params, "network", 100),
        subject: headline.replace(/\.$/, ""),
        chip: "Evidence review",
        status: { label: "Assigned", tone: "warning" },
        display: amountOf(params),
        reference: reference(params),
        root: "evidence-review",
        headline,
        line: `You’ve been assigned to check the ${subject.what}.`,
        button: "Start review",
      },
      params,
      context,
    );
  },
  // M17 (new, approved 2026-10-09)
  "money.payout_receipt_rejected": simple({
    subject: "A payout receipt was rejected",
    chip: "Payout",
    status: { label: "Receipt rejected", tone: "danger" },
    root: "payout-receipt-rejected",
    headline: "A payout receipt was rejected.",
    line: "The withdrawal stays on hold. See what to do next in Wallet.",
    button: "Open withdrawal",
  }),
  // M10
  "money.pocket_move_done": (params, context) => {
    onlyParams(params, [...money, "from", "to"]);
    const from = param(params, "from", 60);
    const to = param(params, "to", 60);
    return build(
      {
        network: param(params, "network", 100),
        subject: "Your pocket move is done",
        chip: "Pocket move",
        status: { label: "Done", tone: "success" },
        display: amountOf(params),
        reference: `${reference(params)} · ${from} → ${to}`,
        root: "move-done",
        headline: "Your pocket move is done.",
        line: `Moved from ${from} to ${to}.`,
        button: "View pockets",
      },
      params,
      context,
    );
  },
  // M11
  "money.pocket_move_declined": simple({
    subject: "Your pocket move was declined",
    chip: "Pocket move",
    status: { label: "Declined", tone: "danger" },
    root: "move-declined",
    headline: "Your pocket move was declined.",
    line: "Nothing moved. See why in Wallet.",
    button: "View details",
  }),
  // M12 (the member is notified of every posted adjustment)
  "money.adjustment_posted": (params, context) => {
    onlyParams(params, [...money, "direction", "actor"]);
    const direction = param(params, "direction", 10);
    if (direction !== "credit" && direction !== "debit") {
      throw new TemplateError("template.param_invalid");
    }
    const credit = direction === "credit";
    const actor = param(params, "actor", nameMax);
    return build(
      {
        network: param(params, "network", 100),
        subject: "Your balance was adjusted",
        chip: "Adjustment",
        status: { label: credit ? "Credit" : "Debit", tone: credit ? "success" : "warning" },
        display: `${credit ? "+" : "−"}${amountOf(params)}`,
        reference: reference(params),
        root: "adjustment-posted",
        headline: "Your balance was adjusted.",
        line: `${actor} posted a ${direction} to your pockets.`,
        button: "View adjustment",
      },
      params,
      context,
    );
  },
  // M16 (new, approved 2026-10-09)
  "money.conversion_posted": (params, context) => {
    onlyParams(params, [...money, "destinationAmount", "destinationCurrency", "actor"]);
    const source = amountOf(params);
    const currency = param(params, "destinationCurrency", 3);
    const names: Readonly<Record<string, string>> = { NGN: "Naira", USD: "US dollars" };
    return build(
      {
        network: param(params, "network", 100),
        subject: "Your money was converted",
        chip: "Conversion",
        status: { label: "Posted", tone: "success" },
        display: amountOf(params, "destinationAmount", "destinationCurrency"),
        reference: `${reference(params)} · ${source}`,
        root: "conversion-posted",
        headline: "Your money was converted.",
        line: `${param(params, "actor", nameMax)} converted ${source} to ${
          names[currency] ?? currency
        }.`,
        button: "View conversion",
      },
      params,
      context,
    );
  },
  // M18 (new, approved 2026-10-09)
  "money.entry_not_posted": (params, context) => {
    onlyParams(params, [...money, "subject"]);
    const subject = subjectOf(params);
    const headline = subject.label === "return"
      ? "Your returned funds weren’t posted."
      : `Your ${subject.label} wasn’t posted.`;
    return build(
      {
        network: param(params, "network", 100),
        subject: headline.replace(/\.$/, ""),
        chip: subject.chip,
        status: { label: "Not posted", tone: "danger" },
        display: amountOf(params),
        reference: reference(params),
        root: "not-posted",
        headline,
        line: "The reviewer didn’t accept it. Nothing changed.",
        button: "View details",
      },
      params,
      context,
    );
  },
  // M13
  "money.transaction_reversed": (params, context) => {
    onlyParams(params, [...money, "reverses"]);
    const reverses = param(params, "reverses", 20);
    if (!/^[A-Z]{3}-[0-9A-Z]{4}-[0-9A-Z]{4}$/.test(reverses)) {
      throw new TemplateError("template.param_invalid");
    }
    return build(
      {
        network: param(params, "network", 100),
        subject: "A transaction was reversed",
        chip: "Reversal",
        status: { label: "Reversed", tone: "warning" },
        display: amountOf(params),
        reference: `${reference(params)} · ${reverses}`,
        root: "reversed",
        headline: "A transaction was reversed.",
        line: "See what changed in Wallet.",
        button: "View reversal",
      },
      params,
      context,
    );
  },
  // M14
  "money.returned_funds": (params, context) => {
    onlyParams(params, [...money, "withdrawal"]);
    const withdrawal = optional(params, "withdrawal", 20);
    return build(
      {
        network: param(params, "network", 100),
        subject: "A payout came back",
        chip: "Returned funds",
        status: { label: "Back in Wallet", tone: "success" },
        display: amountOf(params),
        reference: withdrawal ? `${reference(params)} · ${withdrawal}` : reference(params),
        root: "returned-funds",
        headline: "A payout came back.",
        line: "The bank returned it, so it’s back in your pocket.",
        button: "View details",
      },
      params,
      context,
    );
  },
  // T01
  "team.invitation_accepted": (params, context) => {
    onlyParams(params, ["network", "member", "firstName", "office", "role", "path"]);
    const member = param(params, "member", nameMax);
    const first = optional(params, "firstName", 80) ?? member;
    return build(
      {
        network: param(params, "network", 100),
        subject: `${first} joined your team`,
        chip: "Invitation",
        status: { label: "Accepted", tone: "success" },
        display: member,
        reference: `${param(params, "office", 100)} · ${role(params)}`,
        root: "invitation-accepted",
        headline: `${first} joined your team.`,
        line: "Identity check is next.",
        button: "View member",
      },
      params,
      context,
    );
  },
  // A10 (Elivate-branded: the platform changed the account)
  "account.status_changed": (params, context) => {
    onlyParams(params, ["status", "path"]);
    param(params, "status", 20);
    return build(
      {
        network: null,
        subject: "Your account status changed",
        chip: "Account",
        status: { label: "Updated", tone: "warning" },
        display: "Account update",
        reference: "Wallet by Elivate",
        root: "account-status",
        headline: "Your account status changed.",
        line: "Sign in to see what it means for you.",
        button: "View account",
      },
      params,
      context,
    );
  },
  // A11
  "account.role_changed": (params, context) => {
    onlyParams(params, ["network", "role", "office", "actor", "path"]);
    const label = role(params);
    const office = param(params, "office", 100);
    return build(
      {
        network: param(params, "network", 100),
        subject: "You have a new role",
        chip: "Membership",
        status: { label: "Role updated", tone: "success" },
        display: label,
        reference: office,
        root: "role-changed",
        headline: "You have a new role.",
        line: `${param(params, "actor", nameMax)} made you ${label} for ${office}.`,
        button: "Open Wallet",
      },
      params,
      context,
    );
  },
  // A12
  "account.membership_ended": (params, context) => {
    onlyParams(params, ["network", "office", "path"]);
    const network = param(params, "network", 100);
    const office = optional(params, "office", 100);
    return build(
      {
        network,
        subject: "Your membership has ended",
        chip: "Membership",
        status: { label: "Ended", tone: "muted" },
        display: "Membership ended",
        reference: office ? `${network} · ${office}` : network,
        root: "membership-ended",
        headline: "Your membership has ended.",
        line: "Your history and statements stay in Wallet.",
        button: "View history",
      },
      params,
      context,
    );
  },
};
