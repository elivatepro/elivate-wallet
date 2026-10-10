// Founder application emails (Blueprint 19; Paper "Emails — Transactional v2"
// A17 approved, A18 not approved, A19 received). Sent by Elivate to an
// applicant who may have no account yet. The decision reason never reaches
// an email; the approval link is rebuilt by the worker (`/founder#t=`).

import { renderLayout, supportEmail } from "./layout.ts";
import {
  appOrigin,
  longDate,
  oneLine,
  onlyParams,
  param,
  type Params,
  type RenderContext,
  type RenderedEmail,
  TemplateError,
} from "./params.ts";

/** The marketing site, where prices and the product story live (owner decision). */
export const marketingUrl = "https://elivatewallet.com";

const signature = "Wallet by Elivate";

function textPart(headline: string, line: string, button: string, url: string, extra?: string) {
  return [
    headline,
    "",
    line,
    "",
    `${button}: ${url}`,
    ...(extra ? ["", extra] : []),
    "",
    `Questions? ${supportEmail}`,
    signature,
  ].join("\n");
}

function received(params: Params, context: RenderContext): RenderedEmail {
  onlyParams(params, ["team"]);
  const team = param(params, "team", 100);
  const origin = appOrigin(context);
  const headline = "We have your application.";
  const line = "Elivate will review it and email you either way.";
  const html = renderLayout({
    brand: "elivate",
    chip: "Founder",
    status: { label: "Received", tone: "muted" },
    display: team,
    reference: "Application received",
    root: "founder-received",
    headline,
    line,
    button: { label: "Visit Elivate", url: marketingUrl },
    assetBase: `${origin}/email`,
  });
  return {
    subject: oneLine("We have your Elivate Wallet application", 200),
    html,
    text: textPart(headline, line, "Visit Elivate", marketingUrl),
  };
}

function approved(params: Params, context: RenderContext): RenderedEmail {
  onlyParams(params, ["team", "expiresAt"]);
  const team = param(params, "team", 100);
  const expires = longDate(param(params, "expiresAt", 40));
  const origin = appOrigin(context);
  const link = context.joinUrl;
  if (!link || !/^https?:\/\/[^\s"'<>]+\/founder#t=[A-Za-z0-9_-]{43}$/.test(link)) {
    throw new TemplateError("template.link_missing");
  }
  const headline = "You’re approved to start your network.";
  const line =
    "Create your account, then set up your network. Your 7-day trial starts when you do.";
  const footnote =
    `This link expires on ${expires}. If you didn’t apply, you can ignore this email.`;
  const html = renderLayout({
    brand: "elivate",
    chip: "Founder",
    status: { label: "Approved", tone: "success" },
    display: team,
    reference: "Application approved",
    root: "founder-approved",
    headline,
    line,
    button: { label: "Create your account", url: link },
    footnote,
    assetBase: `${origin}/email`,
  });
  return {
    subject: oneLine("You’re approved to start your network on Elivate Wallet", 200),
    html,
    text: textPart(headline, line, "Create your account", link, footnote),
  };
}

function rejected(params: Params, context: RenderContext): RenderedEmail {
  onlyParams(params, ["team"]);
  const team = param(params, "team", 100);
  const origin = appOrigin(context);
  const headline = "We can’t approve your application.";
  const line = "You can apply again after 30 days.";
  const support = `mailto:${supportEmail}`;
  const html = renderLayout({
    brand: "elivate",
    chip: "Founder",
    status: { label: "Not approved", tone: "danger" },
    display: team,
    reference: "Application reviewed",
    root: "founder-rejected",
    headline,
    line,
    button: { label: "Contact support", url: support },
    assetBase: `${origin}/email`,
  });
  return {
    subject: oneLine("Your Elivate Wallet application", 200),
    html,
    text: textPart(headline, line, "Contact support", support),
  };
}

export const founderRenderers = {
  "founder.application_received": received,
  "founder.application_approved": approved,
  "founder.application_rejected": rejected,
} as const;
