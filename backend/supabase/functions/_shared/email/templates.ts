// Email templates (Blueprint 03 — B4, owner decision 4, P-06). Each outbox
// template key has one renderer. Params come from the database and are
// display values only; every value is HTML-escaped by the Paper layout
// ("Emails — Transactional v2", layout.ts).

import { escapeHtml, renderLayout } from "./layout.ts";

export { escapeHtml };

export interface RenderedEmail {
  readonly subject: string;
  readonly html: string;
  readonly text: string;
}

export interface RenderContext {
  /** Join link, built by the worker from the invitation's token id. */
  readonly joinUrl?: string;
  /** App origin (APP_ORIGIN), for "Open Wallet" buttons. */
  readonly appUrl?: string;
}

type Params = Readonly<Record<string, unknown>>;

export class TemplateError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "TemplateError";
  }
}

/** Header-safe single line (subjects): no control characters, bounded length. */
function oneLine(value: string, max: number): string {
  // deno-lint-ignore no-control-regex
  return value.replace(/[\u0000-\u001f\u007f]+/g, " ").trim().slice(0, max);
}

function param(params: Params, name: string, max = 200): string {
  const value = params[name];
  if (typeof value !== "string" || value.trim() === "" || value.length > max) {
    throw new TemplateError("template.param_invalid");
  }
  return value;
}

function onlyParams(params: Params, allowed: readonly string[]): void {
  for (const key of Object.keys(params)) {
    if (!allowed.includes(key)) throw new TemplateError("template.param_unknown");
  }
}

/** App origin for buttons and images; required by every template. */
function appOrigin(context: RenderContext): string {
  const appUrl = context.appUrl;
  if (!appUrl || !/^https?:\/\/[^\s"'<>#?]+$/.test(appUrl)) {
    throw new TemplateError("template.link_missing");
  }
  return appUrl.replace(/\/+$/, "");
}

/** "8 October 2026" in UTC. */
function longDate(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) throw new TemplateError("template.param_invalid");
  return date.toLocaleDateString("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  });
}

function invitationIssued(params: Params, context: RenderContext): RenderedEmail {
  onlyParams(params, ["network", "office", "role", "reference", "expiresAt"]);
  const network = param(params, "network", 100);
  const office = param(params, "office", 100);
  const role = param(params, "role", 40);
  const reference = param(params, "reference", 20);
  if (!/^INV-[0-9A-Z]{4}-[0-9A-Z]{4}$/.test(reference)) {
    throw new TemplateError("template.param_invalid");
  }
  const expires = longDate(param(params, "expiresAt", 40));
  const origin = appOrigin(context);
  const joinUrl = context.joinUrl;
  if (!joinUrl || !/^https?:\/\/[^\s"'<>]+#t=[A-Za-z0-9_-]{43}$/.test(joinUrl)) {
    throw new TemplateError("template.link_missing");
  }

  const subject = oneLine(`You're invited to join ${network} on Elivate Wallet`, 200);
  const headline = "Your place on the team is ready.";
  const line = `${network} invited you to join as ${role}.`;
  const footnote =
    `This invitation expires on ${expires}. If you weren't expecting it, you can ignore this email. Reference ${reference}`;
  const html = renderLayout({
    brand: { network },
    chip: "Invitation",
    display: network,
    reference: `${office} · ${role}`,
    root: "invitation",
    headline,
    line,
    button: { label: "Accept invitation", url: joinUrl },
    footnote,
    assetBase: `${origin}/email`,
  });
  const text = [
    headline,
    "",
    line,
    "",
    `Accept invitation: ${joinUrl}`,
    "",
    `This invitation expires on ${expires}. If you weren't expecting it, you can ignore this email.`,
    "",
    `Reference ${reference}`,
  ].join("\n");
  return { subject, html, text };
}

/** "8 October 2026, 14:05 UTC". */
function longDateTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) throw new TemplateError("template.param_invalid");
  const time = date.toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: "UTC",
  });
  return `${longDate(iso)}, ${time} UTC`;
}

const payoutAlertCopy: Readonly<
  Record<string, {
    subject: string;
    display: string;
    status: string;
    line: (bank: string, at: string) => string;
  }>
> = {
  added: {
    subject: "A payout account was added to your Wallet",
    display: "New payout account",
    status: "Added",
    line: (bank, at) => `A ${bank} account was added to your Elivate Wallet on ${at}.`,
  },
  replaced: {
    subject: "A payout account was replaced in your Wallet",
    display: "Payout account replaced",
    status: "Replaced",
    line: (bank, at) => `A ${bank} account replaced one of your payout accounts on ${at}.`,
  },
  deactivated: {
    subject: "A payout account was removed from your Wallet",
    display: "Payout account removed",
    status: "Removed",
    line: (bank, at) => `Your ${bank} payout account was removed on ${at}.`,
  },
  primary_changed: {
    subject: "Your main payout account changed",
    display: "Main account changed",
    status: "Changed",
    line: (bank, at) => `Your ${bank} account became your main payout account on ${at}.`,
  },
  name_mismatch: {
    subject: "A payout account needs your attention",
    display: "Name doesn't match",
    status: "Needs attention",
    line: (bank, at) =>
      `On ${at} we found that the name on your ${bank} account doesn't match the name on your NIN, so it can't receive withdrawals.`,
  },
};

/** W-17 holder alert: bank name, what changed and when; never account digits. */
function payoutAccountAlert(params: Params, context: RenderContext): RenderedEmail {
  onlyParams(params, ["action", "bankName", "at"]);
  const copy = payoutAlertCopy[param(params, "action", 40)];
  if (!copy) throw new TemplateError("template.param_invalid");
  const bank = param(params, "bankName", 100);
  const at = longDateTime(param(params, "at", 40));
  const appUrl = appOrigin(context);
  const mismatch = params.action === "name_mismatch";
  const footnote = mismatch
    ? "Update your bank record or NIN, or add another account. Account numbers are never sent by email."
    : "If this wasn't you, reset your PIN and contact Elivate support straight away. Account numbers are never sent by email.";

  const subject = oneLine(copy.subject, 200);
  const line = copy.line(bank, at);
  const html = renderLayout({
    brand: "elivate",
    chip: "Payout accounts",
    status: { label: copy.status, tone: mismatch ? "danger" : "warning" },
    display: copy.display,
    reference: at,
    root: "payout",
    headline: `${copy.subject}.`,
    line,
    button: { label: "Open Wallet", url: appUrl },
    footnote,
    assetBase: `${appUrl}/email`,
  });
  const text = [
    copy.subject,
    "",
    line,
    "",
    `Open Wallet: ${appUrl}`,
    "",
    footnote,
  ].join("\n");
  return { subject, html, text };
}

const ninReviewCopy = {
  approved: {
    subject: "Your identity is confirmed",
    status: { label: "Confirmed", tone: "success" },
    display: "NIN confirmed",
    root: "confirmed",
    headline: "Your identity is confirmed.",
    line: "Your name is now set for payouts.",
    button: "Open Wallet",
  },
  rejected: {
    subject: "We couldn't confirm your identity",
    status: { label: "Not confirmed", tone: "danger" },
    display: "NIN review",
    root: "retry",
    headline: "We couldn't confirm your identity.",
    line: "Check your details in Wallet and ask again.",
    button: "Try again",
  },
} as const;

/**
 * Leader-review outcome (Blueprint 06, Paper A14b/A14c). Network and office
 * only: never the NIN, the typed name or the reviewer's reason (the app does
 * not show the reason to the person either).
 */
function ninReviewDecided(params: Params, context: RenderContext): RenderedEmail {
  onlyParams(params, ["decision", "network", "office"]);
  const decision = param(params, "decision", 20);
  if (decision !== "approved" && decision !== "rejected") {
    throw new TemplateError("template.param_invalid");
  }
  const copy = ninReviewCopy[decision];
  const network = param(params, "network", 100);
  const office = params.office === undefined ? undefined : param(params, "office", 100);
  const appUrl = appOrigin(context);

  const html = renderLayout({
    brand: { network },
    chip: "Identity",
    status: copy.status,
    display: copy.display,
    ...(office ? { reference: office } : {}),
    root: copy.root,
    headline: copy.headline,
    line: copy.line,
    button: { label: copy.button, url: appUrl },
    assetBase: `${appUrl}/email`,
  });
  const text = [
    copy.headline,
    "",
    copy.line,
    "",
    `${copy.button}: ${appUrl}`,
    "",
    `${network} · Powered by Elivate Wallet`,
  ].join("\n");
  return { subject: oneLine(copy.subject, 200), html, text };
}

type Renderer = (params: Params, context: RenderContext) => RenderedEmail;

/** Template key → version → renderer. Must match outbox.templates rows. */
const registry: Readonly<Record<string, Readonly<Record<number, Renderer>>>> = {
  "invitation.issued": { 1: invitationIssued },
  "payout_account.alert": { 1: payoutAccountAlert },
  "identity.nin_review_decided": { 1: ninReviewDecided },
};

export function renderEmail(
  template: string,
  version: number,
  params: Params,
  context: RenderContext = {},
): RenderedEmail {
  const renderer = registry[template]?.[version];
  if (!renderer) throw new TemplateError("template.unknown");
  return renderer(params, context);
}
