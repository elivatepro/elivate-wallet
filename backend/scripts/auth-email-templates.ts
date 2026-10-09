// Supabase Auth email templates in the Paper "Emails — Transactional v2"
// layout (A01 verify, A03 reset, A04 email change, A05 email changed, A06
// password changed). Generated from the same layout as the outbox emails so
// both paths look alike. Links and images use Go template variables
// ({{ .SiteURL }}, {{ .TokenHash }}, ...), so one set serves every project.
//
//   deno run --allow-write=supabase/templates scripts/auth-email-templates.ts
//     writes supabase/templates/*.html (local stack + review copy)
//   deno run scripts/auth-email-templates.ts --payload
//     prints the Management API PATCH body for /v1/projects/{ref}/config/auth
//     (templates and subjects only; never `supabase config push`).
//
// Sign-up, Magic Link and Recovery use token_hash links to
// /auth/confirm (decision 38, Blueprint 10); the others keep {{ .ConfirmationURL }}.

import { type EmailLayout, renderLayout } from "../supabase/functions/_shared/email/layout.ts";

const site = "{{ .SiteURL }}";
const assetBase = `${site}/email`;
const footnoteNotYou =
  "If this wasn't you, reset your PIN and contact Elivate support straight away.";

type Body = Omit<EmailLayout, "assetBase" | "brand">;

function page(body: Body): string {
  return renderLayout({ ...body, brand: "elivate", assetBase });
}

// The Magic Link template carries PIN resets (security function) and the
// invitation sign-in link for people who already have an account
// (invitations function, emailRedirectTo = APP_ORIGIN/join).
const joining = `{{ if eq .RedirectTo (printf "%s/join" .SiteURL) }}`;

interface AuthTemplate {
  readonly key: string;
  readonly subject: string;
  readonly html: string;
}

const securityNotice = (
  key: string,
  subject: string,
  display: string,
  headline: string,
  root: EmailLayout["root"],
  reference?: string,
): AuthTemplate => ({
  key,
  subject,
  html: page({
    chip: "Security",
    status: { label: "Changed", tone: "warning" },
    display,
    ...(reference ? { reference } : {}),
    root,
    headline,
    line: "Not you? Secure your account now.",
    button: { label: "Secure my account", url: site },
    footnote: footnoteNotYou,
  }),
});

export const authTemplates: readonly AuthTemplate[] = [
  {
    key: "confirmation",
    subject: "Confirm your Elivate Wallet email",
    html: page({
      chip: "Account",
      display: "Verify your email",
      reference: "{{ .Email }}",
      root: "verify",
      headline: "One tap to confirm it's you.",
      line: "Confirm this address to finish setting up Wallet.",
      button: {
        label: "Verify email",
        url: `${site}/auth/confirm?token_hash={{ .TokenHash }}&type=signup`,
      },
      footnote: "If you didn't ask to join Elivate Wallet, you can ignore this email.",
    }),
  },
  {
    key: "magic_link",
    subject:
      `${joining}Continue joining on Elivate Wallet{{ else }}Reset your Elivate Wallet PIN{{ end }}`,
    html: `${joining}${
      page({
        chip: "Invitation",
        display: "Continue joining",
        reference: "{{ .Email }}",
        root: "invitation",
        headline: "Confirm it's you to join.",
        line: "Use this link to carry on with your invitation.",
        button: {
          label: "Continue",
          url: `${site}/auth/confirm?token_hash={{ .TokenHash }}&type=magiclink`,
        },
        footnote: "If you weren't expecting an invitation, you can ignore this email.",
      })
    }{{ else }}${
      page({
        chip: "Security",
        display: "Reset your PIN",
        reference: "{{ .Email }}",
        root: "reset",
        headline: "Choose a new PIN.",
        line: "Didn't ask for this? You can ignore this email.",
        button: {
          label: "Reset PIN",
          url: `${site}/auth/confirm?token_hash={{ .TokenHash }}&type=magiclink`,
        },
        footnote: "The link works for 15 minutes.",
      })
    }{{ end }}`,
  },
  {
    key: "invite",
    subject: "You're invited to Elivate Wallet",
    html: page({
      chip: "Invitation",
      display: "You're invited",
      reference: "{{ .Email }}",
      root: "invitation",
      headline: "Your place on the team is ready.",
      line: "Accept to set up your Wallet.",
      button: { label: "Accept invitation", url: "{{ .ConfirmationURL }}" },
      footnote: "If you weren't expecting this, you can ignore this email.",
    }),
  },
  {
    key: "recovery",
    subject: "Reset your Elivate Wallet password",
    html: page({
      chip: "Security",
      display: "Reset password",
      reference: "{{ .Email }}",
      root: "reset",
      headline: "Choose a new password.",
      line: "Didn't ask for this? You can ignore this email.",
      // Blueprint 10: token_hash link to the POST Continue page, like sign-up.
      button: {
        label: "Reset password",
        url: `${site}/auth/confirm?token_hash={{ .TokenHash }}&type=recovery`,
      },
    }),
  },
  {
    key: "email_change",
    subject: "Confirm your new Elivate Wallet email",
    html: page({
      chip: "Account",
      display: "New email",
      reference: "{{ .NewEmail }}",
      root: "email-change",
      headline: "Confirm your new address.",
      line: "Your sign-in email changes once you confirm.",
      button: { label: "Confirm email", url: "{{ .ConfirmationURL }}" },
      footnote: "If you didn't ask for this change, you can ignore this email.",
    }),
  },
  {
    key: "reauthentication",
    subject: "{{ .Token }} is your Elivate Wallet code",
    html: page({
      chip: "Security",
      display: "{{ .Token }}",
      reference: "Verification code",
      root: "reset",
      headline: "Your verification code.",
      line: "Enter this code to continue. It expires shortly.",
      footnote: "If you didn't ask for a code, you can ignore this email.",
    }),
  },
  securityNotice(
    "email_changed_notification",
    "Your Elivate Wallet email was changed",
    "Email changed",
    "Your sign-in email was changed.",
    "email-changed",
    "Now {{ .Email }}",
  ),
  securityNotice(
    "password_changed_notification",
    "Your Elivate Wallet password was changed",
    "Password changed",
    "Your password was changed.",
    "password-changed",
  ),
  securityNotice(
    "phone_changed_notification",
    "Your Elivate Wallet phone number was changed",
    "Phone changed",
    "Your phone number was changed.",
    "password-changed",
  ),
  securityNotice(
    "mfa_factor_enrolled_notification",
    "A verification method was added to your Elivate Wallet",
    "Method added",
    "A verification method was added.",
    "password-changed",
  ),
  securityNotice(
    "mfa_factor_unenrolled_notification",
    "A verification method was removed from your Elivate Wallet",
    "Method removed",
    "A verification method was removed.",
    "password-changed",
  ),
  securityNotice(
    "identity_linked_notification",
    "A sign-in method was linked to your Elivate Wallet",
    "Sign-in linked",
    "A new sign-in method was linked.",
    "password-changed",
    "{{ .Provider }}",
  ),
  securityNotice(
    "identity_unlinked_notification",
    "A sign-in method was removed from your Elivate Wallet",
    "Sign-in removed",
    "A sign-in method was removed.",
    "password-changed",
    "{{ .Provider }}",
  ),
];

/** Management API field names for one template. */
export function payload(): Record<string, string> {
  const body: Record<string, string> = {};
  for (const t of authTemplates) {
    body[`mailer_subjects_${t.key}`] = t.subject;
    body[`mailer_templates_${t.key}_content`] = t.html;
  }
  return body;
}

if (import.meta.main) {
  if (Deno.args.includes("--payload")) {
    console.log(JSON.stringify(payload()));
  } else {
    const dir = new URL("../supabase/templates/", import.meta.url);
    for (const t of authTemplates) {
      await Deno.writeTextFile(new URL(`${t.key}.html`, dir), t.html + "\n");
    }
    console.log(`wrote ${authTemplates.length} templates`);
  }
}
