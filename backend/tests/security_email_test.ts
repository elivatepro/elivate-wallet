// Blueprint 14 — A06 Password changed, A07 New sign-in, A08 PIN changed
// (Paper "Emails — Transactional v2"): Elivate-branded, Paper copy, never an IP.
import { assert, assertEquals, assertThrows } from "@std/assert";
import { renderEmail, TemplateError } from "../supabase/functions/_shared/email/templates.ts";

const appUrl = "https://app.elivatewallet.com";

Deno.test("A06 and A08 show the change and the UTC time on the Elivate layout", () => {
  const a06 = renderEmail("security.password_changed", 1, {
    at: "2026-10-07T08:14:00Z",
    path: "/app/account",
  }, { appUrl });
  assertEquals(a06.subject, "Your Elivate Wallet password was changed");
  assert(a06.html.includes("Password changed"));
  assert(a06.html.includes("7 Oct 2026, 08:14 UTC"));
  assert(a06.html.includes("Not you? Secure your account now."));
  assert(a06.html.includes("Secure my account"));
  assert(a06.html.includes(`${appUrl}/email/mark.png`), "Elivate sender");
  assert(a06.html.includes(`href="${appUrl}/app/account"`));

  const a08 = renderEmail("security.pin_changed", 1, {
    at: "2026-10-07T08:20:00Z",
    path: "/app/account",
  }, { appUrl });
  assertEquals(a08.subject, "Your Wallet PIN was changed");
  assert(a08.html.includes("PIN changed"));
  assert(a08.html.includes("Not you? Reset your PIN now."));
  assert(a08.html.includes("Review security"));
});

Deno.test("A07 names the device and place; new place gets its own status and headline", () => {
  const device = renderEmail("security.new_sign_in", 1, {
    device: "Windows · Chrome",
    city: "Lagos",
    country: "NG",
    reason: "new_device",
    path: "/app/account/devices",
  }, { appUrl });
  assert(device.html.includes("Windows · Chrome · Lagos"));
  assert(device.html.includes("New device"));
  assert(device.html.includes("Review sessions"));
  assert(device.text.includes(`${appUrl}/app/account/devices`));

  const place = renderEmail("security.new_sign_in", 1, {
    device: "Mac · Safari",
    country: "GH",
    reason: "new_location",
    path: "/app/account/devices",
  }, { appUrl });
  assert(place.html.includes("Mac · Safari · Ghana"), "country name when there is no city");
  assert(place.html.includes("New location"));
  assert(place.html.includes("Your account signed in from a new place."));

  const unknown = renderEmail("security.new_sign_in", 1, {
    device: "Linux · Firefox",
    country: "XX",
    reason: "new_device",
    path: "/app/account/devices",
  }, { appUrl });
  assert(unknown.html.includes("Linux · Firefox</"), "no place for an unknown country");
});

Deno.test("A07 escapes the device and city and refuses unknown params (an IP never renders)", () => {
  const email = renderEmail("security.new_sign_in", 1, {
    device: "<b>x</b>",
    city: "Lagos & Co",
    reason: "new_device",
    path: "/app/account/devices",
  }, { appUrl });
  assert(!email.html.includes("<b>x</b>"));
  assert(email.html.includes("Lagos &amp; Co"));
  assertThrows(
    () =>
      renderEmail("security.new_sign_in", 1, {
        device: "Mac · Chrome",
        ip: "102.89.1.10",
        reason: "new_device",
        path: "/app/account/devices",
      }, { appUrl }),
    TemplateError,
  );
  assertThrows(
    () =>
      renderEmail("security.new_sign_in", 1, {
        device: "Mac · Chrome",
        reason: "because",
        path: "/app/account/devices",
      }, { appUrl }),
    TemplateError,
  );
  assertThrows(
    () =>
      renderEmail("security.pin_changed", 1, { at: "yesterday", path: "/app/account" }, { appUrl }),
    TemplateError,
  );
});
