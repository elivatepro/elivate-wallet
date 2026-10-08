// Paystack adapter against a fake fetch. Paystack itself is never called.
import { assert, assertEquals, assertThrows } from "@std/assert";
import {
  localTestOrigin,
  paystackProvider,
  safeName,
} from "../supabase/functions/_shared/name_lookup.ts";

const secret = "sk_test_" + "a1".repeat(20);

interface Seen {
  url: URL;
  init: RequestInit;
}

function fakeFetch(
  respond: (url: URL) => Response | Promise<Response>,
): { fetcher: typeof fetch; seen: Seen[] } {
  const seen: Seen[] = [];
  const fetcher = ((input: string | URL | Request, init: RequestInit = {}) => {
    const url = new URL(input instanceof Request ? input.url : input.toString());
    seen.push({ url, init });
    return Promise.resolve(respond(url));
  }) as typeof fetch;
  return { fetcher, seen };
}

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

Deno.test("resolve: key only in the Authorization header, fixed origin, no redirects", async () => {
  const { fetcher, seen } = fakeFetch(() =>
    json(200, { status: true, data: { account_number: "0123456789", account_name: "ADA OBI" } })
  );
  const provider = paystackProvider(secret, { fetcher });
  const outcome = await provider.resolve("058", "0123456789");
  assertEquals(outcome, { kind: "resolved", accountName: "ADA OBI" });
  const call = seen[0];
  assert(call);
  assertEquals(call.url.origin, "https://api.paystack.co");
  assertEquals(call.url.pathname, "/bank/resolve");
  assertEquals(call.url.searchParams.get("account_number"), "0123456789");
  assertEquals(call.url.searchParams.get("bank_code"), "058");
  assertEquals(call.url.toString().includes(secret), false);
  assertEquals(new Headers(call.init.headers).get("authorization"), `Bearer ${secret}`);
  assertEquals(call.init.redirect, "error");
});

Deno.test("resolve: an answer about another account is rejected", async () => {
  const { fetcher } = fakeFetch(() =>
    json(200, { status: true, data: { account_number: "9999999999", account_name: "SOMEONE" } })
  );
  const outcome = await paystackProvider(secret, { fetcher }).resolve("058", "0123456789");
  assertEquals(outcome.kind, "unavailable");
});

Deno.test("resolve: 422 and 400 with status false are not_found", async () => {
  for (const status of [400, 422]) {
    const { fetcher } = fakeFetch(() =>
      json(status, { status: false, message: "Could not resolve account name" })
    );
    assertEquals(
      await paystackProvider(secret, { fetcher }).resolve("058", "0123456789"),
      { kind: "not_found" },
    );
  }
});

Deno.test("resolve: 429 is unavailable with retryAfterSeconds", async () => {
  const { fetcher } = fakeFetch(() => json(429, { status: false }, { "x-ratelimit-reset": "42" }));
  assertEquals(
    await paystackProvider(secret, { fetcher }).resolve("058", "0123456789"),
    { kind: "unavailable", retryAfterSeconds: 42 },
  );
});

Deno.test("resolve: 5xx, 401, malformed JSON and bad names are unavailable", async () => {
  const responses = [
    () => json(503, { status: false }),
    () => json(401, { status: false, message: "Invalid key" }),
    () => new Response("not json", { status: 200 }),
    () => json(200, { status: true, data: { account_number: "0123456789", account_name: "" } }),
    () =>
      json(200, {
        status: true,
        data: { account_number: "0123456789", account_name: "ADA\u0007OBI" },
      }),
    () =>
      json(200, {
        status: true,
        data: { account_number: "0123456789", account_name: "A".repeat(161) },
      }),
  ];
  for (const respond of responses) {
    const { fetcher } = fakeFetch(respond);
    const outcome = await paystackProvider(secret, { fetcher }).resolve("058", "0123456789");
    assertEquals(outcome.kind, "unavailable");
  }
});

Deno.test("resolve: oversize body is unavailable", async () => {
  const { fetcher } = fakeFetch(() => new Response("x".repeat(300 * 1024), { status: 200 }));
  const outcome = await paystackProvider(secret, { fetcher }).resolve("058", "0123456789");
  assertEquals(outcome.kind, "unavailable");
});

Deno.test("resolve: timeout is unavailable", async () => {
  const fetcher =
    ((_input: unknown, init: RequestInit = {}) =>
      new Promise<Response>((_resolve, reject) => {
        init.signal?.addEventListener("abort", () =>
          reject(new DOMException("aborted", "AbortError")));
      })) as typeof fetch;
  const outcome = await paystackProvider(secret, { fetcher, timeoutMs: 20 }).resolve(
    "058",
    "0123456789",
  );
  assertEquals(outcome.kind, "unavailable");
});

Deno.test("resolve: network errors never leak the key or number", async () => {
  const fetcher = (() => Promise.reject(new Error(`boom ${secret} 0123456789`))) as typeof fetch;
  const outcome = await paystackProvider(secret, { fetcher }).resolve("058", "0123456789");
  assertEquals(outcome, { kind: "unavailable" });
});

Deno.test("resolve: malformed input never reaches the network", async () => {
  const { fetcher, seen } = fakeFetch(() => json(200, {}));
  const provider = paystackProvider(secret, { fetcher });
  assertEquals(await provider.resolve("058", "12345"), { kind: "not_found" });
  assertEquals(await provider.resolve("05 8", "0123456789"), { kind: "not_found" });
  assertEquals(seen.length, 0);
});

Deno.test("bank list: pages by cursor and keeps active NUBAN banks only", async () => {
  const { fetcher, seen } = fakeFetch((url) => {
    if (!url.searchParams.get("next")) {
      return json(200, {
        status: true,
        data: [
          {
            name: "Access Bank",
            slug: "access-bank",
            code: "044",
            active: true,
            is_deleted: false,
            type: "nuban",
          },
          {
            name: "Old Bank",
            slug: "old",
            code: "001",
            active: false,
            is_deleted: false,
            type: "nuban",
          },
          {
            name: "Deleted Bank",
            slug: "del",
            code: "002",
            active: true,
            is_deleted: true,
            type: "nuban",
          },
          {
            name: "Ghana Bank",
            slug: "gh",
            code: "003",
            active: true,
            is_deleted: false,
            type: "ghipss",
          },
          {
            name: "Bad Code",
            slug: "bad",
            code: "x y",
            active: true,
            is_deleted: false,
            type: "nuban",
          },
        ],
        meta: { next: "cursor-2" },
      });
    }
    return json(200, {
      status: true,
      data: [
        {
          name: "ALAT by WEMA",
          slug: "alat",
          code: "035A",
          active: true,
          is_deleted: false,
          type: "nuban",
        },
        {
          name: "Access Bank duplicate",
          slug: "dup",
          code: "044",
          active: true,
          is_deleted: false,
          type: "nuban",
        },
      ],
      meta: { next: null },
    });
  });
  const outcome = await paystackProvider(secret, { fetcher }).listBanks();
  assertEquals(outcome, {
    kind: "ok",
    banks: [
      { code: "044", name: "Access Bank", slug: "access-bank" },
      { code: "035A", name: "ALAT by WEMA", slug: "alat" },
    ],
  });
  assertEquals(seen.length, 2);
  const first = seen[0];
  assert(first);
  assertEquals(first.url.pathname, "/bank");
  assertEquals(first.url.searchParams.get("country"), "nigeria");
  assertEquals(first.url.searchParams.get("type"), "nuban");
  assertEquals(seen[1]?.url.searchParams.get("next"), "cursor-2");
  assertEquals(first.url.toString().includes(secret), false);
});

Deno.test("bank list: stops after 10 pages", async () => {
  let page = 0;
  const { fetcher, seen } = fakeFetch(() =>
    json(200, {
      status: true,
      data: [{ name: `Bank ${page}`, code: String(100 + page++), active: true, is_deleted: false }],
      meta: { next: "again" },
    })
  );
  const outcome = await paystackProvider(secret, { fetcher }).listBanks();
  assertEquals(seen.length, 10);
  assertEquals(outcome.kind === "ok" ? outcome.banks.length : 0, 10);
});

Deno.test("bank list: failures and empty lists are unavailable", async () => {
  for (
    const respond of [
      () => json(500, {}),
      () => json(200, { status: false }),
      () => json(200, { status: true, data: [] }),
    ]
  ) {
    const { fetcher } = fakeFetch(respond);
    assertEquals(await paystackProvider(secret, { fetcher }).listBanks(), { kind: "unavailable" });
  }
});

Deno.test("the secret key format is checked", () => {
  assertThrows(() => paystackProvider("pk_test_abc"));
  assertThrows(() => paystackProvider(""));
});

Deno.test("provider names are trimmed and bounded", () => {
  assertEquals(safeName("  ADA   OBI "), "ADA OBI");
  assertEquals(safeName(""), null);
  assertEquals(safeName(42), null);
  assertEquals(safeName("ADA\u0085OBI"), null);
});

Deno.test("test origin override is honoured for local hosts only", () => {
  assertEquals(
    localTestOrigin("http://host.docker.internal:54399/x"),
    "http://host.docker.internal:54399",
  );
  assertEquals(localTestOrigin("http://127.0.0.1:1"), "http://127.0.0.1:1");
  assertEquals(localTestOrigin("https://evil.example"), undefined);
  assertEquals(localTestOrigin("not a url"), undefined);
  assertEquals(localTestOrigin(undefined), undefined);
});
