import { assertEquals, assertNotEquals, assertRejects } from "@std/assert";
import { createAccountCrypto } from "../supabase/functions/_shared/account_crypto.ts";

const encKey = "11".repeat(32);
const otherEncKey = "22".repeat(32);
const hmacKey = "33".repeat(32);
const owner = "00000000-0000-0000-0000-0000000000a1";
const otherOwner = "00000000-0000-0000-0000-0000000000a2";

function make(enc = encKey, hmac = hmacKey) {
  return createAccountCrypto({
    encryption: new Map([[1, enc]]),
    currentVersion: 1,
    fingerprint: hmac,
  });
}

Deno.test("round trip keeps leading zeros", async () => {
  const c = await make();
  const sealed = await c.seal(owner, "058", "0012345678");
  assertEquals(sealed.last4, "5678");
  assertEquals(sealed.keyVersion, 1);
  assertEquals(await c.open(owner, sealed.ciphertext, 1), "0012345678");
});

Deno.test("ciphertext fits the database shape and never contains the digits", async () => {
  const c = await make();
  const sealed = await c.seal(owner, "058", "0123456789");
  assertEquals(/^[A-Za-z0-9+/]{40,200}={0,2}$/.test(sealed.ciphertext), true);
  assertEquals(sealed.ciphertext.includes("0123456789"), false);
  assertEquals(/^[0-9a-f]{64}$/.test(sealed.fingerprint), true);
});

Deno.test("each seal uses a fresh IV", async () => {
  const c = await make();
  const a = await c.seal(owner, "058", "0123456789");
  const b = await c.seal(owner, "058", "0123456789");
  assertNotEquals(a.ciphertext, b.ciphertext);
  assertEquals(a.fingerprint, b.fingerprint);
});

Deno.test("AAD binds the owner and key version", async () => {
  const c = await make();
  const sealed = await c.seal(owner, "058", "0123456789");
  await assertRejects(() => c.open(otherOwner, sealed.ciphertext, 1));
  await assertRejects(() => c.open(owner, sealed.ciphertext, 2));
});

Deno.test("a wrong key fails", async () => {
  const sealed = await (await make()).seal(owner, "058", "0123456789");
  const other = await make(otherEncKey);
  await assertRejects(() => other.open(owner, sealed.ciphertext, 1));
});

Deno.test("tampered ciphertext fails", async () => {
  const c = await make();
  const sealed = await c.seal(owner, "058", "0123456789");
  const bytes = Uint8Array.from(atob(sealed.ciphertext), (ch) => ch.charCodeAt(0));
  bytes[bytes.length - 1] = (bytes[bytes.length - 1] ?? 0) ^ 1;
  const tampered = btoa(String.fromCharCode(...bytes));
  await assertRejects(() => c.open(owner, tampered, 1));
});

Deno.test("fingerprint is stable per key, bank-specific and differs across keys", async () => {
  const a = await make();
  const b = await make(encKey, "44".repeat(32));
  const one = (await a.seal(owner, "058", "0123456789")).fingerprint;
  assertEquals((await a.seal(otherOwner, "058", "0123456789")).fingerprint, one);
  assertNotEquals((await a.seal(owner, "044", "0123456789")).fingerprint, one);
  assertNotEquals((await b.seal(owner, "058", "0123456789")).fingerprint, one);
});

Deno.test("keys are validated at start-up", async () => {
  await assertRejects(() => make("short"));
  await assertRejects(() => make(encKey, "zz".repeat(32)));
  await assertRejects(() => make(encKey, encKey));
  await assertRejects(() =>
    createAccountCrypto({ encryption: new Map(), currentVersion: 1, fingerprint: hmacKey })
  );
});

Deno.test("only 10-digit numbers are sealed", async () => {
  const c = await make();
  await assertRejects(() => c.seal(owner, "058", "123456789"));
  await assertRejects(() => c.seal(owner, "058", "01234567890"));
  await assertRejects(() => c.seal(owner, "058", "01234 6789"));
});
