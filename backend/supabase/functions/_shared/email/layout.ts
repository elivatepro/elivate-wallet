// Paper "Emails — Transactional v2" layout (owner-approved P-06 system):
// sender header, dark hero band with a Root pose, headline, one line, a coral
// pill button and a quiet footer. Light by default with a dark counterpart for
// clients that honour prefers-color-scheme, and a 320px-friendly mobile rule.
// Images are served by the app (frontend/static/email/) from `assetBase`.
// Every text input is HTML-escaped here; callers pass raw display values.

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Root poses shipped in frontend/static/email/ as root-<name>.png (333×448). */
export type RootPose =
  | "verify"
  | "invitation"
  | "reset"
  | "email-change"
  | "email-changed"
  | "password-changed"
  | "payout"
  | "review"
  | "confirmed"
  | "retry"
  // Blueprint 13: M-series, T01 and A10–A12 (Paper "Emails — Transactional v2").
  | "income-posted"
  | "withdrawal-submitted"
  | "withdrawal-awaiting"
  | "withdrawal-approved"
  | "withdrawal-completed"
  | "withdrawal-rejected"
  | "withdrawal-cancelled"
  | "payout-correction"
  | "evidence-review"
  | "move-done"
  | "move-declined"
  | "adjustment-posted"
  | "reversed"
  | "returned-funds"
  | "conversion-posted"
  | "payout-receipt-rejected"
  | "not-posted"
  | "invitation-accepted"
  | "account-status"
  | "role-changed"
  | "membership-ended"
  // Blueprint 14: A07 and A08.
  | "new-sign-in"
  | "pin-changed"
  // Blueprint 15: M15.
  | "statement-ready"
  // Blueprint 16: B01–B05.
  | "payment-received"
  | "renewal-reminder"
  | "owner-assigned"
  | "seats-almost-full"
  | "plan-paused"
  // Blueprint 17: T02–T05.
  | "backup-ready"
  | "backup-failed"
  | "restore-update"
  | "branding-changed"
  // Blueprint 19: A17–A19.
  | "founder-received"
  | "founder-approved"
  | "founder-rejected";

export type StatusTone = "success" | "warning" | "danger" | "muted";

export interface EmailLayout {
  /** Sender row: the network (initial tile) or Elivate (coral mark). */
  readonly brand: { readonly network: string } | "elivate";
  readonly chip: string;
  readonly status?: { readonly label: string; readonly tone: StatusTone };
  readonly display: string;
  /** Mono line under the display (office, reference, masked address). */
  readonly reference?: string;
  readonly root: RootPose;
  readonly headline: string;
  readonly line: string;
  /** Omitted for code emails (Auth reauthentication). */
  readonly button?: { readonly label: string; readonly url: string };
  /** Small print in the footer (expiry, "if this wasn't you"). */
  readonly footnote?: string;
  /** Absolute origin + path for images, without a trailing slash. */
  readonly assetBase: string;
}

const statusColor: Readonly<Record<StatusTone, string>> = {
  success: "#43C48B",
  warning: "#F2B85E",
  danger: "#F57875",
  muted: "#A9B0B3",
};

/** Owner-designated support inbox (member build plan, U-11), in every footer. */
export const supportEmail = "support@elivatewallet.com";

const font = "Lexend,'Segoe UI',Helvetica,Arial,sans-serif";
const mono = "'IBM Plex Mono','SFMono-Regular',Consolas,'Liberation Mono',monospace";

const styles = `
:root{color-scheme:light dark;supported-color-schemes:light dark}
body{margin:0;padding:0;-webkit-text-size-adjust:100%}
a.ew-button{mso-padding-alt:0}
@media (prefers-color-scheme:dark){
.ew-canvas{background:#111314!important}
.ew-card{background:#1A1D1E!important;border-color:#2A2F31!important}
.ew-text{color:#F2F4F4!important}
.ew-muted{color:#A9B0B3!important}
.ew-faint{color:#7D868A!important}
.ew-rule{border-top-color:#FFFFFF14!important}
.ew-tile{background:#F2F4F4!important;color:#111314!important}
}
[data-ogsc] .ew-canvas{background:#111314!important}
[data-ogsc] .ew-card{background:#1A1D1E!important;border-color:#2A2F31!important}
[data-ogsc] .ew-text{color:#F2F4F4!important}
[data-ogsc] .ew-muted{color:#A9B0B3!important}
[data-ogsc] .ew-faint{color:#7D868A!important}
@media (max-width:480px){
.ew-outer{padding:12px!important}
.ew-pad{padding-left:20px!important;padding-right:20px!important}
.ew-hero-wrap{padding-left:10px!important;padding-right:10px!important}
.ew-hero-copy{padding:18px!important;height:160px!important}
.ew-display{font-size:24px!important;line-height:28px!important;overflow-wrap:break-word!important;word-break:normal!important}
.ew-root-cell{width:92px!important;padding-right:4px!important}
.ew-root{width:88px!important;height:118px!important}
.ew-button-table{width:100%!important}
.ew-headline{font-size:24px!important;line-height:30px!important}
.ew-button-cell{width:100%!important}
.ew-button{display:block!important;text-align:center!important}
}`;

function sender(brand: EmailLayout["brand"], assetBase: string): string {
  if (brand === "elivate") {
    return `<td width="24" style="width:24px;"><img src="${assetBase}/mark.png" width="24" height="24" alt="" style="display:block;border:0;"></td>
<td class="ew-text" style="padding-left:10px;font-family:${font};font-size:15px;line-height:20px;font-weight:500;color:#212628;">Elivate Wallet</td>`;
  }
  const name = brand.network.trim();
  const initial = escapeHtml(Array.from(name)[0]?.toUpperCase() ?? "E");
  return `<td width="24" class="ew-tile" align="center" style="width:24px;height:24px;border-radius:5px;background:#212628;font-family:${font};font-size:14px;line-height:24px;font-weight:600;color:#FFFFFF;">${initial}</td>
<td class="ew-text" style="padding-left:10px;font-family:${font};font-size:15px;line-height:20px;font-weight:500;color:#212628;">${
    escapeHtml(name)
  }</td>`;
}

export function renderLayout(input: EmailLayout): string {
  const base = input.assetBase;
  const button = input.button
    ? `<table role="presentation" class="ew-button-table" cellpadding="0" cellspacing="0" border="0"><tr>
<td class="ew-button-cell" bgcolor="#FF7F4F" style="border-radius:999px;background:#FF7F4F;">
<a class="ew-button" href="${
      escapeHtml(input.button.url)
    }" style="display:inline-block;padding:14px 24px;font-family:${font};font-size:15px;line-height:20px;font-weight:600;color:#14100E;text-decoration:none;border-radius:999px;">${
      escapeHtml(input.button.label)
    }</a>
</td>
</tr></table>`
    : "";
  const status = input.status
    ? `<td style="padding-left:8px;white-space:nowrap;font-family:${font};font-size:13px;line-height:16px;color:${
      statusColor[input.status.tone]
    };">${escapeHtml(input.status.label)}</td>`
    : "";
  const reference = input.reference
    ? `<div style="padding-top:6px;word-break:normal;overflow-wrap:anywhere;font-family:${mono};font-size:13px;line-height:16px;color:#A9B0B3;">${
      escapeHtml(input.reference)
    }</div>`
    : "";
  const brandFooter = input.brand === "elivate"
    ? "Wallet by Elivate"
    : `${input.brand.network.trim()} · Powered by Elivate Wallet`;
  const footnote = input.footnote
    ? `<div class="ew-muted" style="font-family:${font};font-size:13px;line-height:20px;color:#5E686B;padding-bottom:4px;">${
      escapeHtml(input.footnote)
    }</div>`
    : "";
  const support =
    `<div class="ew-muted" style="font-family:${font};font-size:13px;line-height:20px;color:#5E686B;padding-bottom:4px;">Questions? <a class="ew-muted" href="mailto:${supportEmail}" style="color:#5E686B;text-decoration:underline;">${supportEmail}</a></div>`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>${escapeHtml(input.headline)}</title>
<style>${styles}</style>
</head>
<body class="ew-canvas" style="margin:0;padding:0;background:#F7F6F3;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;">${escapeHtml(input.line)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="ew-canvas" style="background:#F7F6F3;">
<tr><td align="center" class="ew-outer" style="padding:24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="ew-card" style="max-width:552px;background:#FFFFFF;border:1px solid #D8DDDE;border-radius:16px;border-collapse:separate;">
<tr><td class="ew-pad" style="padding:22px 32px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
${sender(input.brand, base)}
</tr></table>
</td></tr>
<tr><td class="ew-hero-wrap" style="padding:0 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#1A1D1E" background="${base}/hero.jpg" style="background:#1A1D1E url('${base}/hero.jpg') 50% 50% / cover no-repeat;border-radius:14px;border-collapse:separate;">
<tr>
<td class="ew-hero-copy" valign="top" style="word-break:break-word;padding:24px;height:176px;">
<table role="presentation" width="100%" height="100%" cellpadding="0" cellspacing="0" border="0" style="height:100%;">
<tr><td valign="top"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td style="background:#2C3133;border-radius:999px;padding:3px 10px;white-space:nowrap;font-family:${font};font-size:12px;line-height:16px;color:#D5DADB;">${
    escapeHtml(input.chip)
  }</td>${status}
</tr></table></td></tr>
<tr><td valign="bottom">
<div class="ew-display" style="overflow-wrap:anywhere;word-break:break-word;font-family:${font};font-size:36px;line-height:42px;font-weight:600;letter-spacing:-0.02em;color:#FFFFFF;">${
    escapeHtml(input.display)
  }</div>${reference}
</td></tr>
</table>
</td>
<td class="ew-root-cell" width="168" valign="bottom" align="right" style="width:168px;padding:0 12px 0 0;vertical-align:bottom;line-height:0;font-size:0;">
<img class="ew-root" src="${base}/root-${input.root}.png" width="156" height="210" alt="" style="display:block;border:0;width:156px;height:210px;">
</td>
</tr>
</table>
</td></tr>
<tr><td class="ew-pad" style="padding:28px 32px 32px;">
<h1 class="ew-text ew-headline" style="margin:0 0 12px;font-family:${font};font-size:26px;line-height:32px;font-weight:600;letter-spacing:-0.02em;color:#212628;">${
    escapeHtml(input.headline)
  }</h1>
<p class="ew-muted" style="margin:0${
    input.button ? " 0 24px" : ""
  };font-family:${font};font-size:16px;line-height:24px;color:#5E686B;">${
    escapeHtml(input.line)
  }</p>
${button}
</td></tr>
<tr><td class="ew-pad ew-rule" style="padding:20px 32px 24px;border-top:1px solid #E6E9EA;">
${footnote}${support}<div class="ew-faint" style="font-family:${font};font-size:13px;line-height:20px;color:#8A9396;">${
    escapeHtml(brandFooter)
  }</div>
</td></tr>
</table>
</td></tr>
</table>
</body>
</html>`;
}
