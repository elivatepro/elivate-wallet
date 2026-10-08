import { assert, assertEquals, assertThrows } from "@std/assert";
import { renderEmail, TemplateError } from "../supabase/functions/_shared/email/templates.ts";

const appUrl = "https://app.elivatewallet.com";
const params = { decision: "approved", network: "Cedar Network", office: "Lagos office" };

Deno.test("NIN review approved: Paper A14b copy, network header, office line", () => {
  const email = renderEmail("identity.nin_review_decided", 1, params, { appUrl });
  assertEquals(email.subject, "Your identity is confirmed");
  assert(email.html.includes("NIN confirmed"));
  assert(email.html.includes(">Confirmed<"));
  assert(email.html.includes("Your name is now set for payouts."));
  assert(email.html.includes("Lagos office"));
  assert(email.html.includes("Cedar Network · Powered by Elivate Wallet"));
  assert(email.html.includes(`${appUrl}/email/root-confirmed.png`));
  assert(email.html.includes(`href="${appUrl}"`));
  assert(email.html.includes(">Open Wallet</a>"));
  assert(email.text.includes(`Open Wallet: ${appUrl}`));
  assertEquals((email.html.match(/<a /g) ?? []).length, 1, "one button");
});

Deno.test("NIN review rejected: Paper A14c copy, no reason, retry pose", () => {
  const email = renderEmail("identity.nin_review_decided", 1, { ...params, decision: "rejected" }, {
    appUrl,
  });
  assertEquals(email.subject, "We couldn't confirm your identity");
  assert(email.html.includes("Not confirmed"));
  assert(email.html.includes("We couldn&#39;t confirm your identity."));
  assert(email.html.includes("Check your details in Wallet and ask again."));
  assert(email.html.includes(">Try again</a>"));
  assert(email.html.includes(`${appUrl}/email/root-retry.png`));
});

Deno.test("NIN review: office is optional; names are escaped", () => {
  const email = renderEmail(
    "identity.nin_review_decided",
    1,
    { decision: "approved", network: "<b>Cedar</b> & Co" },
    { appUrl },
  );
  assert(email.html.includes("&lt;b&gt;Cedar&lt;/b&gt; &amp; Co"));
  assertEquals(email.html.includes("<b>Cedar"), false);
  assertEquals(email.html.includes("Lagos office"), false);
});

Deno.test("NIN review: unknown params, decisions and a missing app link fail", () => {
  for (
    const [p, context] of [
      [{ ...params, reason: "Name unreadable" }, { appUrl }],
      [{ ...params, ninLast4: "1234" }, { appUrl }],
      [{ ...params, decision: "pending" }, { appUrl }],
      [{ ...params, network: "" }, { appUrl }],
      [params, {}],
      [params, { appUrl: "javascript:alert(1)" }],
    ] as const
  ) {
    assertThrows(() => renderEmail("identity.nin_review_decided", 1, p, context), TemplateError);
  }
});
