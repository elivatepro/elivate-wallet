import { assertEquals, assertMatch, assertNotEquals } from "@std/assert";
import {
  cleanName,
  ninFingerprint,
  nubanKycProvider,
  parseNinResponse,
} from "../supabase/functions/_shared/nin_provider.ts";

const KEY = "ab".repeat(32);

Deno.test("fingerprint: deterministic hex HMAC, key-dependent", async () => {
  const a = await ninFingerprint(KEY, "12345678901");
  assertMatch(a, /^[0-9a-f]{64}$/);
  assertEquals(a, await ninFingerprint(KEY, "12345678901"));
  assertNotEquals(a, await ninFingerprint("cd".repeat(32), "12345678901"));
  assertNotEquals(a, await ninFingerprint(KEY, "12345678902"));
});

Deno.test("parse: nested record with names → found, title-cased, phone kept", () => {
  const outcome = parseNinResponse({
    status: true,
    data: {
      firstname: "ADAEZE",
      middlename: "CHIOMA",
      surname: "OKAFOR",
      telephoneno: "08031234567",
      photo: "base64...",
      residence_AdressLine1: "1 Street",
    },
  });
  assertEquals(outcome, {
    kind: "found",
    record: {
      givenName: "Adaeze",
      middleNames: ["Chioma"],
      surname: "Okafor",
      phone: "08031234567",
    },
  });
});

Deno.test("parse: other key spellings and a missing phone", () => {
  const outcome = parseNinResponse({ result: [{ FirstName: "Bola", LastName: "Ade-Johnson" }] });
  assertEquals(outcome, {
    kind: "found",
    record: { givenName: "Bola", middleNames: [], surname: "Ade-Johnson", phone: null },
  });
});

Deno.test("parse: explicit no-record answers are not_found", () => {
  assertEquals(parseNinResponse({ status: false, message: "NIN not found" }).kind, "not_found");
  assertEquals(parseNinResponse({ message: "No record found" }).kind, "not_found");
});

Deno.test("parse: unknown shapes never burn a check", () => {
  const outcome = parseNinResponse({ weird: { nested: 1 }, status: "ok" });
  assertEquals(outcome.kind, "unavailable");
});

Deno.test("cleanName refuses digits and markup", () => {
  assertEquals(cleanName("<b>x</b>"), null);
  assertEquals(cleanName("John2"), null);
  assertEquals(cleanName("o'NEIL"), "O'Neil");
});

Deno.test("provider: request shape and status mapping", async () => {
  const seen: Request[] = [];
  const answer = (status: number, body: unknown) =>
    nubanKycProvider("secret-key", {
      baseUrl: "https://kyc.example/",
      fetch: (input, init) => {
        seen.push(new Request(input as string, init));
        return Promise.resolve(new Response(JSON.stringify(body), { status }));
      },
    });
  const found = await answer(200, { data: { firstname: "A", surname: "B" } }).verify("12345678901");
  assertEquals(found.kind, "found");
  assertEquals(
    new URL(seen[0]!.url).toString(),
    "https://kyc.example/api/nin-data?nin_no=12345678901",
  );
  assertEquals(seen[0]!.headers.get("authorization"), "Bearer secret-key");
  assertEquals((await answer(404, {}).verify("12345678901")).kind, "not_found");
  assertEquals((await answer(401, {}).verify("12345678901")).kind, "unavailable");
  assertEquals((await answer(503, {}).verify("12345678901")).kind, "unavailable");
  const failing = nubanKycProvider("k", { fetch: () => Promise.reject(new TypeError("down")) });
  assertEquals((await failing.verify("12345678901")).kind, "unavailable");
});
