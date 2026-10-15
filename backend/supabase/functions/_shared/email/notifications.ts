// Notification emails (Blueprint 13): Paper "Emails — Transactional v2"
// M01–M14, M16–M18 (approved 2026-10-09), T01, A10–A12, (Blueprint 14) the
// A06–A08 security emails and (Blueprint 15) M15 Statement ready, on the shared
// layout, (Blueprint 16) B01–B05 billing and (Blueprint 17) T02–T05 team
// settings and backups. Money emails show the exact
// amount and the public reference only
// (P-06): never balances, account digits, bank details, reasons or evidence.
// One exception (Blueprint 40, owner decision 2026-10-15): M02 and M03 quote
// what the withdrawal is for, in the words of whoever placed it.
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
  /^\/app(\/[a-z][a-z-]*)*(\?withdrawal=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$|^\/app\/billing\/payments\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

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

/** "7 Oct 2026, 09:20 UTC" (Paper A06/A08 hero line; short so 320 px wraps at a space). */
function heroDateTime(iso: string): string {
  const date = new Date(iso);
  if (!/^\d{4}-\d{2}-\d{2}T/.test(iso) || Number.isNaN(date.getTime())) {
    throw new TemplateError("template.param_invalid");
  }
  const day = date.toLocaleDateString("en-GB", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  });
  const time = date.toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: "UTC",
  });
  return `${day}, ${time} UTC`;
}

const regions = new Intl.DisplayNames(["en"], { type: "region" });

/** "Nigeria" from "NG"; nothing for Cloudflare's unknown/Tor codes. */
function countryName(code: string | undefined): string | undefined {
  if (!code || !/^[A-Z]{2}$/.test(code) || code === "XX") return undefined;
  try {
    return regions.of(code);
  } catch {
    return undefined;
  }
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
  readonly note?: { readonly label: string; readonly text: string };
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
    ...(spec.note ? { note: spec.note } : {}),
    button: { label: spec.button, url },
    assetBase: `${origin}/email`,
  });
  const text = [
    spec.headline,
    "",
    spec.line,
    "",
    ...(spec.note ? [`${spec.note.label}: “${spec.note.text}”`, ""] : []),
    ...(spec.reference ? [spec.reference, ""] : []),
    `${spec.button}: ${url}`,
    "",
    `Questions? ${supportEmail}`,
    spec.network === null ? "Wallet by Elivate" : `${spec.network} · Powered by Elivate Wallet`,
  ].join("\n");
  return { subject: oneLine(spec.subject, 200), html, text };
}

type Renderer = (params: Params, context: RenderContext) => RenderedEmail;

/** Blueprint 40: what the withdrawal is for (3–500 characters; optional for older events). */
function reasonNote(params: Params): Spec["note"] {
  const value = params["reason"];
  if (value === undefined) return undefined;
  // Characters as the API and database count them, not UTF-16 units.
  if (typeof value !== "string") throw new TemplateError("template.param_invalid");
  const length = [...value.replace(/^ +| +$/g, "")].length;
  if (length < 3 || length > 500) throw new TemplateError("template.param_invalid");
  return { label: "Reason", text: value.trim() };
}

const money = ["network", "amount", "currency", "reference", "path"] as const;

/** "5 Oct 2026, 11:40" (WAT, from the database). */
function takenAt(params: Params): string {
  const value = param(params, "taken", 30);
  if (!/^[0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}, [0-9]{2}:[0-9]{2}$/.test(value)) {
    throw new TemplateError("template.param_invalid");
  }
  return value;
}

/** T04 copy for each W-24 status (labels from backups.status_label). */
const restoreCopy: Readonly<
  Record<string, { tone: StatusTone; subject: string; headline: string; line: string }>
> = {
  "Requested": {
    tone: "warning",
    subject: "We've received your restore request",
    headline: "We’ve received your restore request.",
    line: "Elivate will check it and email you.",
  },
  "Checking the backup": {
    tone: "warning",
    subject: "Your restore request is being checked",
    headline: "Elivate is checking your backup.",
    line: "We’ll email you when it’s done.",
  },
  "In review": {
    tone: "warning",
    subject: "Your restore request is in review",
    headline: "Your restore request is in review.",
    line: "We’ll email you when it’s done.",
  },
  "Restoring": {
    tone: "warning",
    subject: "Your restore is under way",
    headline: "Your restore is under way.",
    line: "We’ll email you when it’s done.",
  },
  "Restored": {
    tone: "success",
    subject: "Your restore is complete",
    headline: "Your restore is complete.",
    line: "Check your network to confirm.",
  },
  "Not restored": {
    tone: "muted",
    subject: "Your restore request was not approved",
    headline: "Your restore request was not approved.",
    line: "Open the request to see why.",
  },
  "Cancelled": {
    tone: "muted",
    subject: "Your restore request was cancelled",
    headline: "Your restore request was cancelled.",
    line: "Nothing was changed.",
  },
  "Failed": {
    tone: "danger",
    subject: "Your restore didn't complete",
    headline: "Your restore didn’t complete.",
    line: "Elivate will contact you about next steps.",
  },
};

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

const periodTitle =
  /^(Q[1-4] )?[0-9]{4}( so far)?$|^[A-Z][a-z]+ [0-9]{4}$|^[0-9]{1,2} [A-Z][a-z]{2}( [0-9]{4})? – [0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}$/;
const formatLabels = [
  "PDF statement",
  "CSV of transactions",
  "Office report PDF",
  "Transactions CSV",
  "Member balances CSV",
];

export const notificationRenderers: Readonly<Record<string, Renderer>> = {
  // M15 (Blueprint 15): a statement or leadership report finished in the
  // background. Hero = the period; mono line = currency and format. Never
  // amounts, balances or a file link: the button opens the app page.
  "money.statement_ready": (params, context) => {
    onlyParams(params, ["network", "title", "currency", "format", "chip", "path"]);
    const title = param(params, "title", 40);
    const currency = param(params, "currency", 3);
    const format = param(params, "format", 40);
    const chip = param(params, "chip", 20);
    if (
      !periodTitle.test(title) || !/^[A-Z]{3}$/.test(currency) || !formatLabels.includes(format)
    ) {
      throw new TemplateError("template.param_invalid");
    }
    if (chip !== "Statement" && chip !== "Report") {
      throw new TemplateError("template.param_invalid");
    }
    const what = chip === "Statement" ? "statement" : "report";
    return build(
      {
        network: param(params, "network", 100),
        subject: `Your ${what} is ready`,
        chip,
        status: { label: "Ready", tone: "success" },
        display: title,
        reference: `${currency} · ${format}`,
        root: "statement-ready",
        headline: `Your ${what} is ready.`,
        line: "Download it securely from Wallet.",
        button: `Get ${what}`,
      },
      params,
      context,
    );
  },
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
  "money.withdrawal_submitted": (params, context) => {
    onlyParams(params, [...money, "reason"]);
    const note = reasonNote(params);
    return build(
      {
        network: param(params, "network", 100),
        subject: "Withdrawal requested",
        chip: "Withdrawal",
        status: { label: "Submitted", tone: "muted" },
        display: amountOf(params),
        reference: reference(params),
        root: "withdrawal-submitted",
        headline: "Withdrawal requested.",
        line: "We’ll email you when your Team Leader reviews it.",
        ...(note ? { note } : {}),
        button: "View request",
      },
      params,
      context,
    );
  },
  // M03
  "money.withdrawal_awaiting_approval": (params, context) => {
    onlyParams(params, [...money, "member", "office", "reason"]);
    const member = param(params, "member", nameMax);
    const note = reasonNote(params);
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
        ...(note ? { note } : {}),
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
  // A06 (Elivate-branded). Both a signed-in change and a reset.
  "security.password_changed": (params, context) => {
    onlyParams(params, ["at", "path"]);
    return build(
      {
        network: null,
        subject: "Your Elivate Wallet password was changed",
        chip: "Security",
        status: { label: "Changed", tone: "warning" },
        display: "Password changed",
        reference: heroDateTime(param(params, "at", 40)),
        root: "password-changed",
        headline: "Your password was changed.",
        line: "Not you? Secure your account now.",
        button: "Secure my account",
      },
      params,
      context,
    );
  },
  // A07: an unusual sign-in (new device, or new place). Never the IP.
  "security.new_sign_in": (params, context) => {
    onlyParams(params, ["device", "city", "country", "reason", "path"]);
    const reason = param(params, "reason", 20);
    if (reason !== "new_device" && reason !== "new_location") {
      throw new TemplateError("template.param_invalid");
    }
    const place = optional(params, "city", 100) ?? countryName(optional(params, "country", 2));
    const newDevice = reason === "new_device";
    return build(
      {
        network: null,
        subject: newDevice
          ? "New sign-in to your Elivate Wallet"
          : "Your Elivate Wallet signed in from a new place",
        chip: "Security",
        status: { label: newDevice ? "New device" : "New location", tone: "warning" },
        display: "New sign-in",
        reference: [param(params, "device", 60), place].filter(Boolean).join(" · "),
        root: "new-sign-in",
        headline: newDevice
          ? "A new device signed in."
          : "Your account signed in from a new place.",
        line: "Don’t recognise it? Sign out other sessions.",
        button: "Review sessions",
      },
      params,
      context,
    );
  },
  // A08
  "security.pin_changed": (params, context) => {
    onlyParams(params, ["at", "path"]);
    return build(
      {
        network: null,
        subject: "Your Wallet PIN was changed",
        chip: "Security",
        status: { label: "Changed", tone: "warning" },
        display: "PIN changed",
        reference: heroDateTime(param(params, "at", 40)),
        root: "pin-changed",
        headline: "Your Wallet PIN was changed.",
        line: "Not you? Reset your PIN now.",
        button: "Review security",
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

  // ── Billing (Blueprint 16): B01–B05 ──────────────────────────────────────
  // B01: the exact amount and Elivate's PAY reference, never Paystack's.
  "billing.payment_received": (params, context) => {
    onlyParams(params, money);
    const network = param(params, "network", 100);
    return build(
      {
        network,
        subject: "Payment received",
        chip: "Billing",
        status: { label: "Paid", tone: "success" },
        display: amountOf(params),
        reference: `${reference(params)} · Paystack`,
        root: "payment-received",
        headline: "Payment received.",
        line: `Your yearly plan for ${network} is paid.`,
        button: "View receipt",
      },
      params,
      context,
    );
  },
  // B02: the renewal amount and its due date (the trial variant says so).
  "billing.renewal_reminder": (params, context) => {
    onlyParams(params, ["network", "amount", "currency", "due", "chip", "path"]);
    const due = param(params, "due", 20);
    const chip = param(params, "chip", 20);
    if (!/^[0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}$/.test(due)) {
      throw new TemplateError("template.param_invalid");
    }
    if (chip !== "Renews soon" && chip !== "Trial ends soon") {
      throw new TemplateError("template.param_invalid");
    }
    const trial = chip === "Trial ends soon";
    return build(
      {
        network: param(params, "network", 100),
        subject: trial ? "Your free trial ends soon" : "Your plan renews soon",
        chip: "Billing",
        status: { label: chip, tone: "warning" },
        display: amountOf(params),
        reference: `Due ${due}`,
        root: "renewal-reminder",
        headline: trial ? "Your free trial ends soon." : "Your plan renews soon.",
        line: trial
          ? "Pay to keep your network running."
          : "Check your billing details are current.",
        button: "Review billing",
      },
      params,
      context,
    );
  },
  // B03
  "billing.owner_assigned": (params, context) => {
    onlyParams(params, ["network", "path"]);
    const network = param(params, "network", 100);
    return build(
      {
        network,
        subject: "You're now the Billing Owner",
        chip: "Billing",
        status: { label: "Assigned", tone: "success" },
        display: "Billing Owner",
        reference: network,
        root: "owner-assigned",
        headline: "You’re now the Billing Owner.",
        line: "Plan and payment emails will come to you.",
        button: "View billing",
      },
      params,
      context,
    );
  },
  // B04: seats used of the plan's cap, once per period at 90%.
  "billing.seats_almost_full": (params, context) => {
    onlyParams(params, ["network", "used", "cap", "path"]);
    const used = param(params, "used", 7);
    const cap = param(params, "cap", 7);
    if (!/^[0-9]{1,7}$/.test(used) || !/^[0-9]{1,7}$/.test(cap)) {
      throw new TemplateError("template.param_invalid");
    }
    const group = (n: string) => n.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    return build(
      {
        network: param(params, "network", 100),
        subject: "You're close to your seat limit",
        chip: "Seats",
        status: { label: "Almost full", tone: "warning" },
        display: `${group(used)} of ${group(cap)}`,
        reference: "people on your plan",
        root: "seats-almost-full",
        headline: "You’re close to your seat limit.",
        line: "Upgrade before new members are blocked.",
        button: "Review plan",
      },
      params,
      context,
    );
  },
  // B05 (copy changed by the owner 2026-10-09: pay to resume).
  "billing.paused": (params, context) => {
    onlyParams(params, ["network", "path"]);
    const network = param(params, "network", 100);
    return build(
      {
        network,
        subject: "Your plan is paused",
        chip: "Billing",
        status: { label: "Paused", tone: "danger" },
        display: network,
        reference: "Plan paused",
        root: "plan-paused",
        headline: "Your plan is paused.",
        line: "History stays available. Pay to turn it back on.",
        button: "Review billing",
      },
      params,
      context,
    );
  },

  // ── Team settings and backups (Blueprint 17): T02–T05 ────────────────────
  // T02: when it was taken and its size; never the file or its location.
  "team.backup_ready": (params, context) => {
    onlyParams(params, ["network", "taken", "size", "path"]);
    const size = param(params, "size", 20);
    if (!/^[0-9]{1,5} (bytes|kB|MB|GB)$/.test(size)) {
      throw new TemplateError("template.param_invalid");
    }
    return build(
      {
        network: param(params, "network", 100),
        subject: "Your team backup is ready",
        chip: "Team Backup Vault",
        status: { label: "Ready", tone: "success" },
        display: "Backup ready",
        reference: `${takenAt(params)} · ${size}`,
        root: "backup-ready",
        headline: "Your team backup is ready.",
        line: "Download it from the vault.",
        button: "Open vault",
      },
      params,
      context,
    );
  },
  // T03
  "team.backup_failed": (params, context) => {
    onlyParams(params, ["network", "taken", "path"]);
    return build(
      {
        network: param(params, "network", 100),
        subject: "A team backup didn't finish",
        chip: "Team Backup Vault",
        status: { label: "Failed", tone: "danger" },
        display: "Backup failed",
        reference: takenAt(params),
        root: "backup-failed",
        headline: "A team backup didn’t finish.",
        line: "Nothing was lost. Try again from the vault.",
        button: "Retry backup",
      },
      params,
      context,
    );
  },
  // T04: one email per W-24 status change, to the requester.
  "team.restore_update": (params, context) => {
    onlyParams(params, ["network", "reference", "status", "path"]);
    const status = param(params, "status", 30);
    const copy = restoreCopy[status];
    if (!copy) throw new TemplateError("template.param_invalid");
    return build(
      {
        network: param(params, "network", 100),
        subject: copy.subject,
        chip: "Team Backup Vault",
        status: { label: status, tone: copy.tone },
        display: "Restore request",
        reference: reference(params),
        root: "restore-update",
        headline: copy.headline,
        line: copy.line,
        button: "View request",
      },
      params,
      context,
    );
  },
  // T05: who changed what, never the values themselves.
  "team.branding_changed": (params, context) => {
    onlyParams(params, ["network", "actor", "summary", "revision", "path"]);
    const summary = param(params, "summary", 120);
    if (!/^the [a-z ,]+$/.test(summary)) throw new TemplateError("template.param_invalid");
    const revision = param(params, "revision", 7);
    if (!/^[1-9][0-9]{0,6}$/.test(revision)) throw new TemplateError("template.param_invalid");
    const what = summary.slice("the ".length);
    return build(
      {
        network: param(params, "network", 100),
        subject: "Your team's branding changed",
        chip: "Branding",
        status: { label: `Revision ${revision}`, tone: "muted" },
        display: "New look",
        reference: `${what.charAt(0).toUpperCase()}${what.slice(1)} updated`,
        root: "branding-changed",
        headline: "Your team’s branding changed.",
        line: `${oneLine(param(params, "actor", nameMax), nameMax)} updated ${summary}.`,
        button: "View branding",
      },
      params,
      context,
    );
  },
};
