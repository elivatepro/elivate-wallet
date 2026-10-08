import { assert, assertEquals, assertThrows } from "@std/assert";
import { renderEmail, TemplateError } from "../supabase/functions/_shared/email/templates.ts";

const appUrl = "https://app.elivatewallet.com";
const params = { action: "added", bankName: "Guaranty Trust Bank", at: "2026-10-08T14:05:09Z" };

Deno.test("payout alert: bank, action and time; button to the app; no reference row", () => {
  const email = renderEmail("payout_account.alert", 1, params, { appUrl });
  assertEquals(email.subject, "A payout account was added to your Wallet");
  assert(email.text.includes("A Guaranty Trust Bank account was added"));
  assert(email.text.includes("8 October 2026, 14:05 UTC"));
  assert(email.text.includes(`Open Wallet: ${appUrl}`));
  assert(email.html.includes(`href="${appUrl}"`));
  assertEquals(email.html.includes("Reference"), false);
});

Deno.test("payout alert: every action has its own subject", () => {
  const subjects = new Set(
    ["added", "replaced", "deactivated", "primary_changed", "name_mismatch"].map((action) =>
      renderEmail("payout_account.alert", 1, { ...params, action }, { appUrl }).subject
    ),
  );
  assertEquals(subjects.size, 5);
  const mismatch = renderEmail("payout_account.alert", 1, { ...params, action: "name_mismatch" }, {
    appUrl,
  });
  assert(mismatch.text.includes("doesn't match the name on your NIN"));
});

Deno.test("payout alert: bank names are escaped and nothing has digits beyond the date", () => {
  const email = renderEmail(
    "payout_account.alert",
    1,
    { ...params, bankName: "<b>Bank</b> & Co" },
    { appUrl },
  );
  assert(email.html.includes("&lt;b&gt;Bank&lt;/b&gt; &amp; Co"));
  assertEquals(email.html.includes("<b>Bank"), false);
  assertEquals(/[0-9]{5,}/.test(email.text), false);
});

Deno.test("payout alert: unknown params, actions, bad times and missing app link fail", () => {
  for (
    const [p, context] of [
      [{ ...params, accountNumber: "0123456789" }, { appUrl }],
      [{ ...params, action: "stolen" }, { appUrl }],
      [{ ...params, at: "yesterday" }, { appUrl }],
      [{ ...params, bankName: "" }, { appUrl }],
      [params, {}],
      [params, { appUrl: "javascript:alert(1)" }],
    ] as const
  ) {
    assertThrows(() => renderEmail("payout_account.alert", 1, p, context), TemplateError);
  }
  assertThrows(() => renderEmail("payout_account.alert", 2, params, { appUrl }), TemplateError);
});
