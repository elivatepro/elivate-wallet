import { assert, assertEquals, assertNotEquals, assertThrows } from "@std/assert";
import {
  createInviteTokens,
  joinLink,
  tokenDigest,
  tokenPattern,
} from "../supabase/functions/_shared/invite_token.ts";
import { renderEmail, TemplateError } from "../supabase/functions/_shared/email/templates.ts";
import {
  createCloudflareTransport,
  type FetchLike,
} from "../supabase/functions/_shared/email/cloudflare.ts";

const secretA = "a".repeat(64);
const secretB = "b".repeat(64);
const tokenId = "00000000-0000-0000-0000-0000000000e1";

// ── Tokens (16) ──

Deno.test("token derivation is deterministic per secret and token id", async () => {
  const a = await createInviteTokens(secretA);
  const b = await createInviteTokens(secretB);
  assertEquals(await a.token(tokenId), await a.token(tokenId));
  assertNotEquals(await a.token(tokenId), await b.token(tokenId));
  assertNotEquals(await a.token(tokenId), await a.token("00000000-0000-0000-0000-0000000000e2"));
  assert(tokenPattern.test(await a.token(tokenId)));
});

Deno.test("issued digest is SHA-256 of the derived token", async () => {
  const tokens = await createInviteTokens(secretA);
  const { tokenId: id, digest } = await tokens.issue();
  assertEquals(digest, await tokenDigest(await tokens.token(id)));
  assert(/^[0-9a-f]{64}$/.test(digest));
});

Deno.test("digest matches the known SHA-256 vector", async () => {
  assertEquals(
    await tokenDigest("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});

Deno.test("a malformed secret is refused", async () => {
  let failed = false;
  try {
    await createInviteTokens("short");
  } catch {
    failed = true;
  }
  assert(failed);
});

Deno.test("join link carries the token in the fragment", () => {
  assertEquals(
    joinLink("https://app.elivatewallet.com/", "T".repeat(43)),
    `https://app.elivatewallet.com/join#t=${"T".repeat(43)}`,
  );
});

// ── Templates (18) ──

const params = {
  network: `Lagos <script>alert("x")</script> & Co`,
  office: "Team A",
  role: "Team Leader",
  reference: "INV-7K3M-9QP2",
  expiresAt: "2026-10-15T09:00:00Z",
};
const joinUrl = `https://app.elivatewallet.com/join#t=${"T".repeat(43)}`;
const appUrl = "https://app.elivatewallet.com";
const context = { joinUrl, appUrl };

Deno.test("invitation email escapes names and follows the Paper A02 layout", () => {
  const email = renderEmail("invitation.issued", 1, params, context);
  assertEquals(
    email.subject,
    `You're invited to join Lagos <script>alert("x")</script> & Co on Elivate Wallet`,
  );
  assert(!email.html.includes("<script>"));
  assert(email.html.includes("Lagos &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; Co"));
  assert(email.html.includes("invited you to join as Team Leader."));
  assert(email.html.includes(">Accept invitation</a>"));
  assert(email.html.includes("Team A · Team Leader"));
  assert(email.html.includes("INV-7K3M-9QP2"));
  assert(email.html.includes("15 October 2026"));
  assert(email.html.includes("#FF7F4F"), "coral button");
  assert(email.html.includes(`${appUrl}/email/root-invitation.png`), "Root pose from the app");
  assert(email.html.includes(`${appUrl}/email/hero.jpg`), "hero band");
  assert(email.html.includes("Powered by Elivate Wallet"));
  assert(email.html.includes(`href="${joinUrl}"`));
  assertEquals((email.html.match(/<a /g) ?? []).length, 1, "one button");
});

Deno.test("invitation email has a plain-text part", () => {
  const email = renderEmail("invitation.issued", 1, params, context);
  assert(email.text.includes(`Accept invitation: ${joinUrl}`));
  assert(email.text.includes("Reference INV-7K3M-9QP2"));
  assert(!/<(a|p|h1|table)[ >]/.test(email.text), "no HTML in the text part");
});

Deno.test("subjects never carry line breaks", () => {
  const email = renderEmail(
    "invitation.issued",
    1,
    { ...params, network: "Lagos\r\nBcc: x" },
    context,
  );
  assert(!/[\r\n]/.test(email.subject));
});

Deno.test("only allowed params render; missing link or unknown template fails", () => {
  assertThrows(
    () => renderEmail("invitation.issued", 1, { ...params, pin: "1234" }, context),
    TemplateError,
  );
  assertThrows(() => renderEmail("invitation.issued", 1, params, { appUrl }), TemplateError);
  assertThrows(() => renderEmail("invitation.issued", 1, params, { joinUrl }), TemplateError);
  assertThrows(
    () => renderEmail("invitation.issued", 1, params, { appUrl, joinUrl: "javascript:alert(1)" }),
    TemplateError,
  );
  assertThrows(() => renderEmail("invitation.issued", 2, params, context), TemplateError);
  assertThrows(() => renderEmail("nope", 1, params, context), TemplateError);
});

// ── Cloudflare adapter (17), fake transport only ──

const config = {
  accountId: "acct-123",
  apiToken: "cf-token-secret",
  fromAddress: "noreply@elivatewallet.com",
  fromName: "Elivate Wallet",
};
const message = {
  to: "new@example.test",
  subject: "Hello",
  html: "<p>Hi</p>",
  text: "Hi",
  correlationId: "outbox:e1:1",
};

function fakeFetch(respond: () => Response | Promise<Response>) {
  const seen: { url: string; init: RequestInit }[] = [];
  const fetch: FetchLike = (url, init) => {
    seen.push({ url, init });
    return Promise.resolve(respond());
  };
  return { fetch, seen };
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

Deno.test("request shape: endpoint, bearer token, named sender and correlation header", async () => {
  const { fetch, seen } = fakeFetch(() =>
    json(200, {
      success: true,
      errors: [],
      messages: [],
      result: { delivered: ["new@example.test"], message_id: "<m1@cf>" },
    })
  );
  const outcome = await createCloudflareTransport(config, { fetch }).send(message);
  assertEquals(outcome, { outcome: "sent", providerStatus: 200, messageId: "<m1@cf>" });
  assertEquals(
    seen[0]?.url,
    "https://api.cloudflare.com/client/v4/accounts/acct-123/email/sending/send",
  );
  assertEquals(
    (seen[0]?.init.headers as Record<string, string>).authorization,
    "Bearer cf-token-secret",
  );
  assertEquals(JSON.parse(String(seen[0]?.init.body)), {
    from: { address: "noreply@elivatewallet.com", name: "Elivate Wallet" },
    to: ["new@example.test"],
    subject: "Hello",
    html: "<p>Hi</p>",
    text: "Hi",
    headers: { "X-Elivate-Outbox": "outbox:e1:1" },
  });
});

Deno.test("status classification", async () => {
  const cases: [Response, string, string | null][] = [
    [
      json(429, { success: false, errors: [{ code: 1 }] }),
      "retryable_failure",
      "provider.rate_limited",
    ],
    [json(503, { success: false }), "retryable_failure", "provider.unavailable"],
    [
      json(400, { success: false, errors: [{ code: 10001, message: "bad" }] }),
      "permanent_failure",
      "provider.rejected.10001",
    ],
    [json(403, { success: false }), "permanent_failure", "provider.rejected"],
    [
      json(200, { success: true, result: { permanent_bounces: ["new@example.test"] } }),
      "permanent_failure",
      "provider.bounced",
    ],
    [
      json(200, { success: true, result: { suppressed_recipients: ["NEW@example.test"] } }),
      "permanent_failure",
      "provider.suppressed",
    ],
    [json(200, { success: false }), "outcome_unknown", "provider.unexpected_response"],
  ];
  for (const [response, outcome, code] of cases) {
    const { fetch } = fakeFetch(() => response);
    const result = await createCloudflareTransport(config, { fetch }).send(message);
    assertEquals(result.outcome, outcome);
    assertEquals("errorCode" in result ? result.errorCode : null, code);
  }
});

Deno.test("network error before sending is retryable; a timeout is an unknown outcome", async () => {
  const refused: FetchLike = () => Promise.reject(new TypeError("connection refused"));
  assertEquals(
    (await createCloudflareTransport(config, { fetch: refused }).send(message)).outcome,
    "retryable_failure",
  );
  const hanging: FetchLike = (_url, init) =>
    new Promise((_resolve, reject) => {
      init.signal?.addEventListener(
        "abort",
        () => reject(new DOMException("aborted", "AbortError")),
      );
    });
  const result = await createCloudflareTransport(config, { fetch: hanging, timeoutMs: 10 }).send(
    message,
  );
  assertEquals(result.outcome, "outcome_unknown");
  assertEquals("errorCode" in result ? result.errorCode : null, "provider.timeout");
});

Deno.test("error codes never carry addresses or tokens", async () => {
  const { fetch } = fakeFetch(() =>
    json(400, {
      success: false,
      errors: [{ code: "new@example.test", message: "cf-token-secret" }],
    })
  );
  const result = await createCloudflareTransport(config, { fetch }).send(message);
  const text = JSON.stringify(result);
  assert(!text.includes("new@example.test"));
  assert(!text.includes("cf-token-secret"));
});
