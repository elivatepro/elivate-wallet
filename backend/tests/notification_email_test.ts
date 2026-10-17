import { assert, assertEquals, assertThrows } from "@std/assert";
import { renderEmail, TemplateError } from "../supabase/functions/_shared/email/templates.ts";
import { formatMoney } from "../supabase/functions/_shared/email/notifications.ts";

const appUrl = "https://app.elivatewallet.com";
const money = {
  network: "Cedar Network",
  amount: "48000.00",
  currency: "NGN",
  reference: "WDR-9C1M-0877",
  path: "/app/withdrawals",
};

// Every Blueprint 13 template with Paper's sample values: headline and pose.
const samples: ReadonlyArray<readonly [string, Record<string, string>, string, string]> = [
  [
    "money.income_posted",
    { ...money, reference: "INC-7F2K-0931", amount: "180000.00" },
    "Income is in your pockets.",
    "income-posted",
  ],
  ["money.withdrawal_submitted", money, "Withdrawal requested.", "withdrawal-submitted"],
  [
    "money.withdrawal_awaiting_approval",
    {
      ...money,
      member: "Ada N.",
      office: "Lagos office",
      path: "/app/queue?withdrawal=0b6d2a52-1d0c-4c55-9a3e-6f5f1c2e9a10",
    },
    "A withdrawal needs your approval.",
    "withdrawal-awaiting",
  ],
  ["money.withdrawal_approved", money, "Your withdrawal is approved.", "withdrawal-approved"],
  [
    "money.withdrawal_completed",
    { ...money, firstName: "Ada" },
    "Your withdrawal is paid.",
    "withdrawal-completed",
  ],
  [
    "money.withdrawal_not_approved",
    money,
    "Your withdrawal wasn’t approved.",
    "withdrawal-rejected",
  ],
  ["money.withdrawal_cancelled", money, "Withdrawal cancelled.", "withdrawal-cancelled"],
  ["money.payout_correction_required", money, "A payout record needs a fix.", "payout-correction"],
  [
    "money.evidence_review_assigned",
    { ...money, subject: "payout", path: "/app/evidence" },
    "A payout needs your review.",
    "evidence-review",
  ],
  [
    "money.payout_receipt_rejected",
    money,
    "A payout receipt was rejected.",
    "payout-receipt-rejected",
  ],
  [
    "money.pocket_move_done",
    {
      ...money,
      reference: "PTR-4B8Q-2210",
      amount: "20000.00",
      from: "Savings",
      to: "Upkeep",
      path: "/app",
    },
    "Your pocket move is done.",
    "move-done",
  ],
  [
    "money.pocket_move_declined",
    { ...money, reference: "PTR-4B8Q-2210" },
    "Your pocket move was declined.",
    "move-declined",
  ],
  [
    "money.adjustment_posted",
    {
      ...money,
      reference: "ADJ-2M6T-0412",
      amount: "12500.00",
      direction: "credit",
      actor: "Ifeoma O.",
      path: "/app/activity",
    },
    "Your balance was adjusted.",
    "adjustment-posted",
  ],
  [
    "money.conversion_posted",
    {
      ...money,
      reference: "CNV-5H2R-0716",
      amount: "180000.00",
      destinationAmount: "120.00",
      destinationCurrency: "USD",
      actor: "Ifeoma O.",
      path: "/app/activity",
    },
    "Your money was converted.",
    "conversion-posted",
  ],
  [
    "money.entry_not_posted",
    { ...money, reference: "ADJ-2M6T-0412", subject: "adjustment", path: "/app/adjust" },
    "Your adjustment wasn’t posted.",
    "not-posted",
  ],
  [
    "money.transaction_reversed",
    { ...money, reference: "REV-3K8D-1140", reverses: "INC-7F2K-0931", path: "/app/activity" },
    "A transaction was reversed.",
    "reversed",
  ],
  [
    "money.returned_funds",
    { ...money, reference: "RTN-6P1C-0388", withdrawal: "WDR-9C1M-0877", path: "/app/activity" },
    "A payout came back.",
    "returned-funds",
  ],
  [
    "team.invitation_accepted",
    {
      network: "Cedar Network",
      member: "Ada Nwosu",
      firstName: "Ada",
      office: "Lagos office",
      role: "member",
      path: "/app/members",
    },
    "Ada joined your team.",
    "invitation-accepted",
  ],
  [
    "account.status_changed",
    { status: "restricted", path: "/app" },
    "Your account status changed.",
    "account-status",
  ],
  [
    "account.role_changed",
    {
      network: "Cedar Network",
      role: "team_leader",
      office: "Lagos office",
      actor: "Ifeoma O.",
      path: "/app",
    },
    "You have a new role.",
    "role-changed",
  ],
  [
    "account.membership_ended",
    { network: "Cedar Network", office: "Abuja office", path: "/app/activity" },
    "Your membership has ended.",
    "membership-ended",
  ],
  // Blueprint 14: A06–A08.
  [
    "security.password_changed",
    { at: "2026-10-07T08:14:00Z", path: "/app/account" },
    "Your password was changed.",
    "password-changed",
  ],
  [
    "security.new_sign_in",
    {
      device: "Windows · Chrome",
      city: "Lagos",
      country: "NG",
      reason: "new_device",
      path: "/app/account/devices",
    },
    "A new device signed in.",
    "new-sign-in",
  ],
  [
    "security.pin_changed",
    { at: "2026-10-07T08:20:00Z", path: "/app/account" },
    "Your Wallet PIN was changed.",
    "pin-changed",
  ],
  [
    "money.statement_ready",
    {
      network: "Cedar Network",
      title: "September 2026",
      currency: "NGN",
      format: "PDF statement",
      chip: "Statement",
      path: "/app/statements",
    },
    "Your statement is ready.",
    "statement-ready",
  ],
  [
    "billing.payment_received",
    {
      network: "Cedar Network",
      amount: "700000.00",
      currency: "NGN",
      reference: "PAY-5R2N-0042",
      path: "/app/billing/payments/0b0e7b5c-6d3a-4f4e-9a52-6c2f1f7e8a10",
    },
    "Payment received.",
    "payment-received",
  ],
  [
    "billing.renewal_reminder",
    {
      network: "Cedar Network",
      amount: "700000.00",
      currency: "NGN",
      due: "12 Jan 2027",
      chip: "Renews soon",
      path: "/app/billing",
    },
    "Your plan renews soon.",
    "renewal-reminder",
  ],
  [
    "billing.owner_assigned",
    { network: "Cedar Network", path: "/app/billing" },
    "You’re now the Billing Owner.",
    "owner-assigned",
  ],
  [
    "billing.seats_almost_full",
    { network: "Cedar Network", used: "384", cap: "400", path: "/app/billing" },
    "You’re close to your seat limit.",
    "seats-almost-full",
  ],
  [
    "billing.paused",
    { network: "Cedar Network", path: "/app/billing" },
    "Your plan is paused.",
    "plan-paused",
  ],
];

Deno.test("Blueprint 45: the owner's withdrawal emails open that withdrawal", () => {
  const path = "/app/withdrawals/0b0e7b5c-6d3a-4f4e-9a52-6c2f1f7e8a10";
  for (const key of ["money.withdrawal_submitted", "money.withdrawal_not_approved"]) {
    const email = renderEmail(key, 1, { ...money, path }, { appUrl });
    assert(email.html.includes(`href="${appUrl}${path}"`), key);
  }
  assertThrows(
    () => renderEmail("money.withdrawal_submitted", 1, { ...money, path: `${path}/x` }, { appUrl }),
    TemplateError,
  );
});

Deno.test("B01 shows the PAY reference with the exact amount; B02–B05 follow Paper", () => {
  const b01 = renderEmail("billing.payment_received", 1, {
    network: "Cedar Network",
    amount: "700000.00",
    currency: "NGN",
    reference: "PAY-5R2N-0042",
    path: "/app/billing",
  }, { appUrl });
  assert(b01.html.includes("₦700,000.00"));
  assert(b01.html.includes("PAY-5R2N-0042 · Paystack"));
  const trial = renderEmail("billing.renewal_reminder", 1, {
    network: "Cedar Network",
    amount: "700000.00",
    currency: "NGN",
    due: "15 Oct 2026",
    chip: "Trial ends soon",
    path: "/app/billing",
  }, { appUrl });
  assert(trial.html.includes("Your free trial ends soon."));
  assert(trial.html.includes("Due 15 Oct 2026"));
  const seats = renderEmail("billing.seats_almost_full", 1, {
    network: "Cedar Network",
    used: "1000",
    cap: "1000",
    path: "/app/billing",
  }, { appUrl });
  assert(seats.html.includes("1,000 of 1,000"));
  const paused = renderEmail("billing.paused", 1, {
    network: "Cedar Network",
    path: "/app/billing",
  }, { appUrl });
  assert(paused.html.includes("History stays available. Pay to turn it back on."));
  assert(paused.html.includes("Review billing"));
  assert(!paused.html.includes("Contact Elivate"));
});

Deno.test("billing emails refuse foreign links, references and chips", () => {
  for (
    const [key, params] of [
      ["billing.payment_received", {
        network: "N",
        amount: "1.00",
        currency: "NGN",
        reference: "PSK_abc",
        path: "/app/billing",
      }],
      ["billing.payment_received", {
        network: "N",
        amount: "1.00",
        currency: "NGN",
        reference: "PAY-5R2N-0042",
        path: "https://evil.example/x",
      }],
      ["billing.renewal_reminder", {
        network: "N",
        amount: "1.00",
        currency: "NGN",
        due: "soon",
        chip: "Renews soon",
        path: "/app/billing",
      }],
      ["billing.renewal_reminder", {
        network: "N",
        amount: "1.00",
        currency: "NGN",
        due: "1 Jan 2027",
        chip: "Pay now!",
        path: "/app/billing",
      }],
      ["billing.seats_almost_full", {
        network: "N",
        used: "many",
        cap: "400",
        path: "/app/billing",
      }],
    ] as const
  ) {
    let threw = false;
    try {
      renderEmail(key, 1, params as Record<string, string>, { appUrl });
    } catch {
      threw = true;
    }
    assert(threw, `${key} refuses ${JSON.stringify(params)}`);
  }
});

/** Blueprint 46: money emails keep the band without Root. */
const plainBand = new Set([
  "income-posted",
  "withdrawal-submitted",
  "withdrawal-awaiting",
  "withdrawal-approved",
  "withdrawal-completed",
  "withdrawal-rejected",
  "withdrawal-cancelled",
  "payout-correction",
  "evidence-review",
  "payout-receipt-rejected",
  "move-done",
  "move-declined",
  "adjustment-posted",
  "conversion-posted",
  "not-posted",
  "reversed",
  "returned-funds",
  "statement-ready",
  "payment-received",
  "renewal-reminder",
  "plan-paused",
]);

Deno.test("every notification email renders on the Paper layout; Root only off money", () => {
  const poses = new Set<string>();
  for (const [key, params, headline, pose] of samples) {
    const email = renderEmail(key, 1, params, { appUrl });
    assert(email.html.includes(headline.replace(/’/g, "’")), `${key}: headline`);
    if (plainBand.has(pose)) {
      assert(!email.html.includes(`${appUrl}/email/root-`), `${key}: no Root on money`);
      assert(!email.html.includes(`class="ew-root-cell"`), `${key}: no Root cell`);
    } else {
      assert(email.html.includes(`${appUrl}/email/root-${pose}.png`), `${key}: pose`);
    }
    assert(
      email.html.includes(`href="${appUrl}${params.path?.replace(/&/g, "&amp;")}"`),
      `${key}: button link`,
    );
    assert(email.html.includes("support@elivatewallet.com"), `${key}: support in the footer`);
    assert(email.text.includes("Questions? support@elivatewallet.com"), `${key}: support in text`);
    assertEquals((email.html.match(/class="ew-button"/g) ?? []).length, 1, `${key}: one button`);
    assert(email.subject.length > 0 && !/[\r\n]/.test(email.subject), `${key}: one-line subject`);
    poses.add(pose);
  }
  assertEquals(poses.size, samples.length, "no pose is repeated");
});

Deno.test("money is formatted from the exact decimal string", () => {
  assertEquals(formatMoney("48000.00", "NGN"), "₦48,000.00");
  assertEquals(formatMoney("1234567890123.45", "NGN"), "₦1,234,567,890,123.45");
  assertEquals(formatMoney("0.50", "USD"), "$0.50");
  assertEquals(formatMoney("100.00", "USD"), "$100.00");
  for (
    const [amount, currency] of [["48000", "NGN"], ["1e5.00", "NGN"], ["-5.00", "NGN"], [
      "5.00",
      "EUR",
    ]]
  ) {
    assertThrows(() => formatMoney(amount!, currency!), TemplateError);
  }
});

Deno.test("M03 names the member and office; M12 signs debits; M16 shows what arrived", () => {
  const m03 = renderEmail("money.withdrawal_awaiting_approval", 1, samples[2]![1], { appUrl });
  assert(m03.html.includes("WDR-9C1M-0877 · Ada N."));
  assert(m03.html.includes("Ada N. requested a payout from Lagos office."));
  assert(m03.html.includes("₦48,000.00"));
  const debit = renderEmail("money.adjustment_posted", 1, {
    ...samples[12]![1],
    direction: "debit",
  }, { appUrl });
  assert(debit.html.includes("−₦12,500.00"));
  assert(debit.html.includes(">Debit<"));
  const m16 = renderEmail("money.conversion_posted", 1, samples[13]![1], { appUrl });
  assert(m16.html.includes("$120.00"));
  assert(m16.html.includes("CNV-5H2R-0716 · ₦180,000.00"));
  assert(m16.html.includes("Ifeoma O. converted ₦180,000.00 to US dollars."));
});

Deno.test("a reason counts characters as the API does (500 with an emoji still sends)", () => {
  const reason = "x".repeat(499) + "\u{1F393}";
  const m02 = renderEmail("money.withdrawal_submitted", 1, { ...money, reason }, { appUrl });
  assert(m02.text.includes("\u{1F393}"));
});

Deno.test("M02 and M03 quote the withdrawal's reason; older events render without it", () => {
  const reason = "School fees <for> the term\nand books";
  const m02 = renderEmail("money.withdrawal_submitted", 1, { ...money, reason }, { appUrl });
  assert(m02.html.includes(">Reason<"));
  assert(m02.html.includes("“School fees &lt;for&gt; the term<br>and books”"));
  assert(m02.text.includes("Reason: “School fees <for> the term\nand books”"));
  const m03 = renderEmail("money.withdrawal_awaiting_approval", 1, { ...samples[2]![1], reason }, {
    appUrl,
  });
  assert(m03.html.includes("“School fees &lt;for&gt; the term<br>and books”"));
  const old = renderEmail("money.withdrawal_submitted", 1, money, { appUrl });
  assert(!old.html.includes(">Reason<"));
  assertThrows(
    () =>
      renderEmail("money.withdrawal_submitted", 1, { ...money, reason: "x".repeat(501) }, {
        appUrl,
      }),
    TemplateError,
  );
  assertThrows(
    () =>
      renderEmail("money.withdrawal_approved", 1, { ...money, reason: "School fees" }, { appUrl }),
    TemplateError,
  );
});

Deno.test("M09 and M18 use the right noun per kind", () => {
  const review = (subject: string) =>
    renderEmail("money.evidence_review_assigned", 1, { ...money, subject, path: "/app/evidence" }, {
      appUrl,
    });
  assertEquals(review("adjustment").subject, "An adjustment needs your review");
  assertEquals(review("conversion").subject, "A conversion needs your review");
  assertEquals(review("returned_funds").subject, "Returned funds need your review");
  assert(review("adjustment").html.includes("check the evidence"));
  const notPosted = renderEmail("money.entry_not_posted", 1, {
    ...money,
    subject: "returned_funds",
  }, { appUrl });
  assert(notPosted.html.includes("Your returned funds weren’t posted."));
  assert(notPosted.html.includes(">Returned funds<"));
});

Deno.test("A10 is Elivate-branded; others carry the network", () => {
  const a10 = renderEmail("account.status_changed", 1, { status: "suspended", path: "/app" }, {
    appUrl,
  });
  assert(a10.html.includes(`${appUrl}/email/mark.png`));
  assert(a10.html.includes("Wallet by Elivate"));
  assertEquals(a10.html.includes("suspended"), false, "the status itself stays in Wallet");
  const m01 = renderEmail("money.income_posted", 1, samples[0]![1], { appUrl });
  assert(m01.html.includes("Cedar Network · Powered by Elivate Wallet"));
});

Deno.test("names are escaped", () => {
  const email = renderEmail("team.invitation_accepted", 1, {
    ...samples[17]![1],
    member: "<img src=x>",
    firstName: "<b>Ada</b>",
  }, { appUrl });
  assertEquals(email.html.includes("<img src=x>"), false);
  assert(email.html.includes("&lt;img src=x&gt;"));
  assertEquals(email.html.includes("<b>Ada</b>"), false);
});

Deno.test("unknown params, bad references, links and roles fail permanently", () => {
  const bad: ReadonlyArray<readonly [string, Record<string, string>, { appUrl?: string }]> = [
    ["money.income_posted", { ...money, accountNumber: "0123456789" }, { appUrl }],
    ["money.income_posted", { ...money, balance: "1.00" }, { appUrl }],
    ["money.income_posted", { ...money, reference: "<script>" }, { appUrl }],
    ["money.income_posted", { ...money, amount: "48000" }, { appUrl }],
    ["money.income_posted", { ...money, path: "https://evil.example/app" }, { appUrl }],
    ["money.income_posted", { ...money, path: "/app/../admin" }, { appUrl }],
    ["money.income_posted", { ...money, path: "/app?next=//evil" }, { appUrl }],
    ["money.income_posted", money, {}],
    ["money.adjustment_posted", { ...money, direction: "sideways", actor: "A" }, { appUrl }],
    ["money.evidence_review_assigned", { ...money, subject: "income" }, { appUrl }],
    ["team.invitation_accepted", { ...samples[17]![1], role: "admin" }, { appUrl }],
    ["money.transaction_reversed", { ...money, reverses: "nope" }, { appUrl }],
  ];
  for (const [key, params, context] of bad) {
    assertThrows(() => renderEmail(key, 1, params, context), TemplateError, undefined, key);
  }
});

Deno.test("names up to the profile's full length still render (first + last ≤ 161)", () => {
  const long = `${"A".repeat(80)} ${"B".repeat(80)}`;
  const t01 = renderEmail("team.invitation_accepted", 1, { ...samples[17]![1], member: long }, {
    appUrl,
  });
  assert(t01.html.includes(long));
  const m12 = renderEmail("money.adjustment_posted", 1, { ...samples[12]![1], actor: long }, {
    appUrl,
  });
  assert(m12.html.includes(long));
});
