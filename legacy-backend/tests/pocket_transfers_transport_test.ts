import {
  handleTransferCommand,
  handleTransferRead,
  parseTransferCommand,
  parseTransferQuery,
  type TransferClient,
} from "../supabase/functions/_shared/pocket-transfers.ts";
function assert(value: unknown): asserts value {
  if (!value) throw Error("Assertion failed");
}
function same(a: unknown, b: unknown) {
  assert(JSON.stringify(a) === JSON.stringify(b));
}
function denied(action: () => unknown) {
  let threw = false;
  try {
    action();
  } catch {
    threw = true;
  }
  assert(threw);
}
const id = (n: number) =>
  `55000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const submit = {
  membershipId: null,
  idempotencyKey: id(1),
  sourceLedgerAccountId: id(2),
  destinationLedgerAccountId: id(3),
  amount: "9007199254740993.123456789012345678",
};
Deno.test("submit parser exact decimal preserves personal selection and rejects client security context", () => {
  same(parseTransferCommand("submit", submit), {
    p_actor_membership_id: null,
    p_idempotency_key: id(1),
    p_source_ledger_account_id: id(2),
    p_destination_ledger_account_id: id(3),
    p_amount: submit.amount,
  });
  for (
    const extra of [
      { actorId: id(4) },
      { sessionId: id(4) },
      { role: "president" },
      { tenantId: id(4) },
      { verified: true },
    ]
  ) denied(() => parseTransferCommand("submit", { ...submit, ...extra }));
  for (
    const amount of [
      0,
      "0",
      "0.00",
      "-1",
      "1e9",
      "1.0000000000000000001",
      "123456789012345678901",
    ]
  ) denied(() => parseTransferCommand("submit", { ...submit, amount }));
  denied(() =>
    parseTransferCommand("submit", { ...submit, membershipId: "personal" })
  );
});
Deno.test("approve reject cancel parser strictly scopes exact existing target and reason", () => {
  same(
    parseTransferCommand("approve", {
      membershipId: id(4),
      idempotencyKey: id(1),
      transferId: id(2),
    }),
    {
      p_actor_membership_id: id(4),
      p_idempotency_key: id(1),
      p_transfer_id: id(2),
    },
  );
  for (const operation of ["reject", "cancel"] as const) {
    assert(
      parseTransferCommand(operation, {
        membershipId: null,
        idempotencyKey: id(1),
        transferId: id(2),
        reason: "  Fixture reason  ",
      }).p_reason === "Fixture reason",
    );
    for (const reason of ["", " ", "x".repeat(501)]) {
      denied(() =>
        parseTransferCommand(operation, {
          membershipId: null,
          idempotencyKey: id(1),
          transferId: id(2),
          reason,
        })
      );
    }
  }
  denied(() =>
    parseTransferCommand("approve", {
      membershipId: null,
      idempotencyKey: id(1),
      transferId: id(2),
      reason: "extra",
    })
  );
});
Deno.test("read cursors and targeted sources reject mixed selectors, invalid contexts and excess query", () => {
  same(parseTransferQuery(new URLSearchParams()), {
    p_actor_membership_id: null,
    p_status: null,
    p_before_created_at: null,
    p_before_transfer_id: null,
    p_transfer_id: null,
    p_search: null,
  });
  assert(
    parseTransferQuery(new URLSearchParams({ search: "  Fixture   Wallet  " }))
      .p_search === "Fixture Wallet",
  );
  for (
    const query of [
      { membershipId: "personal" },
      { actorId: id(9) },
      { status: "approved" },
      { beforeId: id(1) },
      { beforeCreatedAt: "tomorrow", beforeId: id(1) },
      { transferId: id(1), search: "wrong" },
    ]
  ) {
    denied(() =>
      parseTransferQuery(
        new URLSearchParams(
          Object.entries(query).filter(([, value]) => value !== undefined).map((
            [key, value],
          ) => [key, String(value)]),
        ),
      )
    );
  }
  denied(() =>
    parseTransferQuery(new URLSearchParams("status=requested&status=completed"))
  );
  denied(() =>
    parseTransferQuery(
      new URLSearchParams({
        afterLedgerAccountId: id(1),
        sourceLedgerAccountId: id(2),
      }),
      true,
    )
  );
  assert(
    parseTransferQuery(
      new URLSearchParams({ afterLedgerAccountId: id(2) }),
      true,
    ).p_after_ledger_account_id === id(2),
  );
});
function transport(result: unknown, error: { code?: string } | null = null) {
  const calls: {
    schema: string;
    rpc: string;
    args: Readonly<Record<string, unknown>>;
  }[] = [];
  const client: TransferClient = {
    schema: (schema) => ({
      rpc: (rpc, args) => {
        calls.push({ schema, rpc, args });
        return Promise.resolve({ data: result, error });
      },
    }),
  };
  return {
    calls,
    authenticate: () =>
      Promise.resolve({ client, userId: id(8), stepUpSessionId: id(9) }),
  };
}
const posted = {
  operation_id: id(10),
  operation_reference: "FIXTURE-TRANSFER",
  status: "requested",
  financial_transaction_id: null,
  reused: false,
};
Deno.test("command authenticates actor and session server-side and emits only narrow core receipt", async () => {
  const t = transport({ ...posted, private_detail: "must not expose" });
  const response = await handleTransferCommand(
    new Request("https://fixture.test/", {
      method: "POST",
      body: JSON.stringify(submit),
    }),
    t.authenticate,
    "submit",
  );
  assert(response.status === 200);
  assert(response.headers.get("Cache-Control") === "no-store");
  same(t.calls, [{
    schema: "command_api",
    rpc: "submit_pocket_transfer",
    args: {
      ...parseTransferCommand("submit", submit),
      p_actor_user_id: id(8),
      p_session_id: id(9),
    },
  }]);
  const body = await response.json();
  same(body.data, posted);
  assert(!JSON.stringify(body).includes("private_detail"));
});
Deno.test("reads authenticate selected membership and never use client actor or session", async () => {
  const t = transport({ items: [], next_cursor: null, restricted: false });
  const response = await handleTransferRead(
    new Request(
      `https://fixture.test/?membershipId=${id(4)}&afterLedgerAccountId=${
        id(2)
      }`,
    ),
    t.authenticate,
    true,
  );
  assert(response.status === 200);
  const call = t.calls[0];
  assert(call);
  assert(
    call.schema === "read_api" &&
      call.rpc === "pocket_transfer_choices",
  );
  assert(
    call.args.p_actor_user_id === id(8) &&
      call.args.p_actor_membership_id === id(4),
  );
  assert(!Object.hasOwn(call.args, "p_session_id"));
});
Deno.test("wrong-target receipts and mismatched terminal journal identity cannot become success", async () => {
  for (
    const data of [
      {
        ...posted,
        operation_id: id(99),
        status: "completed",
        financial_transaction_id: id(11),
      },
      { ...posted, status: "completed", financial_transaction_id: null },
      { ...posted, status: "requested" },
    ]
  ) {
    const t = transport(data);
    const response = await handleTransferCommand(
      new Request("https://fixture.test/", {
        method: "POST",
        body: JSON.stringify({
          membershipId: null,
          idempotencyKey: id(1),
          transferId: id(10),
        }),
      }),
      t.authenticate,
      "approve",
    );
    assert(response.status !== 200);
  }
  const t = transport({
    ...posted,
    reused: true,
    status: "completed",
    financial_transaction_id: id(11),
  });
  assert(
    (await handleTransferCommand(
      new Request("https://fixture.test/", {
        method: "POST",
        body: JSON.stringify(submit),
      }),
      t.authenticate,
      "submit",
    )).status === 200,
  );
});
Deno.test("method and selector validation occur without authentication or RPC; stepup stays actionable", async () => {
  const t = transport(null);
  assert(
    (await handleTransferRead(
      new Request("https://fixture.test/?role=president"),
      t.authenticate,
    )).status === 400,
  );
  assert(
    (await handleTransferCommand(
      new Request("https://fixture.test/"),
      t.authenticate,
      "submit",
    )).status === 400,
  );
  assert(t.calls.length === 0);
  const challenge = transport(null, { code: "P0401" });
  const response = await handleTransferCommand(
    new Request("https://fixture.test/", {
      method: "POST",
      body: JSON.stringify(submit),
    }),
    challenge.authenticate,
    "submit",
  );
  assert(response.status === 403);
  assert((await response.json()).error.code === "step_up_required");
});
