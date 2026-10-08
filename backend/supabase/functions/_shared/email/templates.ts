// Email templates (Blueprint 03 — B4, owner decision 4, P-06). Each outbox
// template key has one renderer. Params come from the database and are
// display values only; every value is HTML-escaped. Copy: a coral hero band,
// a headline, one line and one button, plus the public reference.

export interface RenderedEmail {
  readonly subject: string;
  readonly html: string;
  readonly text: string;
}

export interface RenderContext {
  /** Join link, built by the worker from the invitation's token id. */
  readonly joinUrl?: string;
}

type Params = Readonly<Record<string, unknown>>;

export class TemplateError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "TemplateError";
  }
}

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
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

const coral = "#FF7F4F";
const canvas = "#F7F6F3";
const surface = "#FFFFFF";
const ink = "#212628";
const muted = "#5B6366";
const border = "#D8DDDE";
const font = "Lexend, 'Segoe UI', Helvetica, Arial, sans-serif";

/** P-06 transactional layout. All arguments must already be escaped. */
function layout(
  input: {
    readonly headline: string;
    readonly line: string;
    readonly buttonLabel: string;
    readonly buttonUrl: string;
    readonly footnote: string;
    readonly reference: string;
  },
): string {
  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>${input.headline}</title></head>
<body style="margin:0;padding:0;background:${canvas};">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${canvas};">
<tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:${surface};border:1px solid ${border};border-radius:16px;overflow:hidden;">
<tr><td style="background:${coral};padding:32px 24px;font-family:${font};font-size:16px;font-weight:700;color:${ink};letter-spacing:0.02em;">Elivate Wallet</td></tr>
<tr><td style="padding:32px 24px 8px;font-family:${font};">
<h1 style="margin:0 0 12px;font-size:24px;line-height:32px;font-weight:600;color:${ink};">${input.headline}</h1>
<p style="margin:0 0 24px;font-size:16px;line-height:24px;color:${ink};">${input.line}</p>
<table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="border-radius:12px;background:${ink};">
<a href="${input.buttonUrl}" style="display:inline-block;padding:12px 32px;font-family:${font};font-size:16px;font-weight:600;line-height:24px;color:${surface};text-decoration:none;border-radius:12px;">${input.buttonLabel}</a>
</td></tr></table>
<p style="margin:24px 0 0;font-size:14px;line-height:20px;color:${muted};">${input.footnote}</p>
</td></tr>
<tr><td style="padding:16px 24px 32px;font-family:${font};font-size:12px;line-height:16px;color:${muted};">Reference <span style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',monospace;color:${ink};">${input.reference}</span></td></tr>
</table>
</td></tr>
</table>
</body>
</html>`;
}

function invitationIssued(params: Params, context: RenderContext): RenderedEmail {
  onlyParams(params, ["network", "office", "role", "reference", "expiresAt"]);
  const network = param(params, "network", 100);
  const role = param(params, "role", 40);
  const reference = param(params, "reference", 20);
  if (!/^INV-[0-9A-Z]{4}-[0-9A-Z]{4}$/.test(reference)) {
    throw new TemplateError("template.param_invalid");
  }
  const expires = longDate(param(params, "expiresAt", 40));
  param(params, "office", 100);
  const joinUrl = context.joinUrl;
  if (!joinUrl || !/^https?:\/\/[^\s"'<>]+#t=[A-Za-z0-9_-]{43}$/.test(joinUrl)) {
    throw new TemplateError("template.link_missing");
  }

  const subject = oneLine(`You're invited to join ${network} on Elivate Wallet`, 200);
  const html = layout({
    headline: `You're invited to ${escapeHtml(network)}`,
    line: `${escapeHtml(network)} invited you to join as ${escapeHtml(role)}.`,
    buttonLabel: "Join",
    buttonUrl: escapeHtml(joinUrl),
    footnote: `This invitation expires on ${
      escapeHtml(expires)
    }. If you weren't expecting it, you can ignore this email.`,
    reference: escapeHtml(reference),
  });
  const text = [
    `You're invited to ${network}`,
    "",
    `${network} invited you to join as ${role}.`,
    "",
    `Join: ${joinUrl}`,
    "",
    `This invitation expires on ${expires}. If you weren't expecting it, you can ignore this email.`,
    "",
    `Reference ${reference}`,
  ].join("\n");
  return { subject, html, text };
}

type Renderer = (params: Params, context: RenderContext) => RenderedEmail;

/** Template key → version → renderer. Must match outbox.templates rows. */
const registry: Readonly<Record<string, Readonly<Record<number, Renderer>>>> = {
  "invitation.issued": { 1: invitationIssued },
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
