// Blueprint 17: the org routes for team settings, brand, quick search, backups
// and restore requests; the exports-worker backup steps; T02–T05.
import { assert, assertEquals, assertThrows } from "@std/assert";
import {
  type Actor,
  createHandler as createOrg,
  type RpcResult,
} from "../supabase/functions/org/handler.ts";
import { createHandler as createWorker } from "../supabase/functions/exports-worker/handler.ts";
import { renderEmail, TemplateError } from "../supabase/functions/_shared/email/templates.ts";

const actor: Actor = {
  userId: "00000000-0000-0000-0000-0000000000a1",
  sessionId: "00000000-0000-0000-0000-00000000a0a1",
};
const membershipId = "00000000-0000-0000-0000-0000000000b1";
const tenantId = "00000000-0000-0000-0000-0000000000e1";
const backupId = "00000000-0000-0000-0000-0000000000f1";
const key = "key-0000000000000001";
const appUrl = "https://app.elivatewallet.com";

function org(result: RpcResult = { data: { ok: true }, error: null }) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const handler = createOrg({
    verifyToken: (token) => Promise.resolve(token === "good" ? actor : null),
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve(result);
    },
    log: () => {},
    allowedOrigins: [],
    appServerSecret: "app-secret",
  });
  return { handler, calls };
}

function request(method: string, path: string, body?: unknown, extra: Record<string, string> = {}) {
  return new Request(`http://localhost/functions/v1/org${path}`, {
    method,
    headers: {
      authorization: "Bearer good",
      "content-type": "application/json",
      "x-membership": membershipId,
      ...extra,
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

async function code(response: Response): Promise<string> {
  return (await response.json()).error?.code ?? "ok";
}

Deno.test("settings save passes the revision and only known fields", async () => {
  const { handler, calls } = org();
  const ok = await handler(request("PATCH", "/settings", {
    expectedRevision: 3,
    fields: { theme: "cobalt", slogan: null },
    idempotencyKey: key,
  }));
  assertEquals(ok.status, 200);
  assertEquals(calls[0]?.fn, "update_team_settings");
  assertEquals(calls[0]?.args.p_expected_revision, 3);
  assertEquals(calls[0]?.args.p_fields, { theme: "cobalt", slogan: null });
  assertEquals(calls[0]?.args.p_membership_id, membershipId);
  for (
    const body of [
      { expectedRevision: 3, fields: { css: "body{}" }, idempotencyKey: key },
      { expectedRevision: 3, fields: {}, idempotencyKey: key },
      { expectedRevision: 3, fields: { slogan: "x".repeat(61) }, idempotencyKey: key },
      { expectedRevision: 3, fields: { theme: 7 }, idempotencyKey: key },
      { expectedRevision: 0, fields: { theme: "fern" }, idempotencyKey: key },
      { expectedRevision: 3, fields: { theme: "fern" } },
    ]
  ) {
    assertEquals(
      await code(await handler(request("PATCH", "/settings", body))),
      "validation_error",
    );
  }
  assertEquals(calls.length, 1);
});

Deno.test("Blueprint 44: the one-open-withdrawal switch is a boolean", async () => {
  const { handler, calls } = org();
  const ok = await handler(request("PATCH", "/settings", {
    expectedRevision: 4,
    fields: { oneOpenWithdrawal: true },
    idempotencyKey: key,
  }));
  assertEquals(ok.status, 200);
  assertEquals(calls[0]?.args.p_fields, { oneOpenWithdrawal: true });
  for (const value of ["true", 1, null, "on"]) {
    assertEquals(
      await code(
        await handler(request("PATCH", "/settings", {
          expectedRevision: 4,
          fields: { oneOpenWithdrawal: value },
          idempotencyKey: key,
        })),
      ),
      "validation_error",
    );
  }
  assertEquals(
    await code(
      await handler(request("PATCH", "/settings", {
        expectedRevision: 4,
        fields: { theme: true },
        idempotencyKey: key,
      })),
    ),
    "validation_error",
  );
  assertEquals(calls.length, 1);
});

Deno.test("restoring a revision needs both revisions", async () => {
  const { handler, calls } = org();
  await handler(request("POST", "/settings/restore", {
    expectedRevision: 5,
    revision: 2,
    idempotencyKey: key,
  }));
  assertEquals(calls[0]?.fn, "restore_team_settings_revision");
  assertEquals(calls[0]?.args.p_revision, 2);
  assertEquals(
    await code(
      await handler(request("POST", "/settings/restore", { revision: 2, idempotencyKey: key })),
    ),
    "validation_error",
  );
});

Deno.test("storage keys go to the app server only", async () => {
  const objectKey = `brand/${tenantId}/${backupId}.png`;
  const { handler, calls } = org({ data: { objectKey, revision: 2 }, error: null });
  const denied = await handler(request("POST", "/brand/asset-key", { kind: "logo" }));
  assertEquals(await code(denied), "authorization_denied");
  const wrong = await handler(
    request("POST", "/brand/asset-key", { kind: "logo" }, { "x-app-server-secret": "nope" }),
  );
  assertEquals(await code(wrong), "authorization_denied");
  assertEquals(calls.length, 0);
  const ok = await handler(
    request("POST", "/brand/asset-key", { kind: "logo" }, { "x-app-server-secret": "app-secret" }),
  );
  assertEquals((await ok.json()).data.objectKey, objectKey);
  const badKind = await handler(
    request("POST", "/brand/upload-key", { ext: "svg" }, { "x-app-server-secret": "app-secret" }),
  );
  assertEquals(await code(badKind), "validation_error");
});

Deno.test("a key of the wrong shape is never passed on", async () => {
  const { handler } = org({ data: { objectKey: "photos/x.png" }, error: null });
  const response = await handler(
    request("POST", "/brand/asset-key", { kind: "icon" }, { "x-app-server-secret": "app-secret" }),
  );
  assertEquals(await code(response), "internal_error");
  const download = await handler(
    request("POST", `/backups/${backupId}/download`, {}, { "x-app-server-secret": "app-secret" }),
  );
  assertEquals(await code(download), "internal_error");
});

Deno.test("backup download returns the key to the app server", async () => {
  const objectKey = `backups/${tenantId}/${backupId}/1.zip`;
  const { handler, calls } = org({ data: { objectKey, fileName: "b.zip" }, error: null });
  const response = await handler(
    request("POST", `/backups/${backupId}/download`, {}, { "x-app-server-secret": "app-secret" }),
  );
  assertEquals((await response.json()).data.objectKey, objectKey);
  assertEquals(calls[0]?.fn, "authorize_backup_download");
  assertEquals(calls[0]?.args.p_backup_id, backupId);
  assert(typeof calls[0]?.args.p_request_id === "string");
});

Deno.test("quick search needs 2 to 80 characters", async () => {
  const { handler, calls } = org({ data: { people: [] }, error: null });
  await handler(request("GET", "/search?q=Nwosu&limit=5"));
  assertEquals(calls[0]?.fn, "quick_search");
  assertEquals(calls[0]?.args.p_query, "Nwosu");
  for (const q of ["a", " b ", "x".repeat(81)]) {
    const response = await handler(request("GET", `/search?q=${encodeURIComponent(q)}`));
    assertEquals(await code(response), "validation_error");
  }
  assertEquals(
    await code(await handler(request("GET", "/search?q=ab&limit=11"))),
    "validation_error",
  );
  assertEquals(await code(await handler(request("GET", "/search?q=ab&x=1"))), "validation_error");
  assertEquals(calls.length, 1);
});

Deno.test("restore requests need a reason of 10 to 500 characters", async () => {
  const { handler, calls } = org();
  await handler(request("POST", "/restores", {
    backupId,
    reason: "Settings changed by mistake",
    idempotencyKey: key,
  }));
  assertEquals(calls[0]?.fn, "request_restore");
  const short = await handler(
    request("POST", "/restores", { backupId, reason: "Too short", idempotencyKey: key }),
  );
  assertEquals(await code(short), "validation_error");
  await handler(request("POST", `/restores/${backupId}/cancel`, { idempotencyKey: key }));
  assertEquals(calls[1]?.fn, "cancel_restore_request");
  assertEquals(calls[1]?.args.p_restore_id, backupId);
});

Deno.test("only W-24 steps can be taken by an operator", async () => {
  const { handler, calls } = org();
  const bad = await handler(request("POST", `/platform/restores/${backupId}/advance`, {
    status: "requested",
    reason: "Back to start",
    idempotencyKey: key,
  }));
  assertEquals(await code(bad), "validation_error");
  await handler(request("POST", `/platform/restores/${backupId}/advance`, {
    status: "in_review",
    reason: "Diff ready",
    idempotencyKey: key,
  }));
  assertEquals(calls[0]?.fn, "platform_advance_restore");
  assertEquals(calls[0]?.args.p_membership_id, undefined);
});

// ── exports-worker: backups ──

function worker() {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const handler = createWorker({
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve({ data: { ok: true }, error: null });
    },
    workerSecret: "s3cret-worker",
    log: () => {},
  });
  return { handler, calls };
}

function workerRequest(method: string, path: string, body?: unknown) {
  return new Request(`http://localhost/functions/v1/exports-worker${path}`, {
    method,
    headers: { authorization: "Bearer s3cret-worker", "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

const files = Array.from({ length: 35 }, (_, i) => ({
  section: `section_${String.fromCharCode(97 + (i % 26))}${i >= 26 ? "x" : ""}`,
  rows: i,
  sha256: "d".repeat(64),
}));

Deno.test("backup steps map to their api functions", async () => {
  const { handler, calls } = worker();
  await handler(workerRequest("POST", "/backups/claim", { worker: "cf:1" }));
  await handler(workerRequest("POST", `/backups/${backupId}/prepare`, { worker: "cf:1" }));
  await handler(workerRequest("GET", `/backups/${backupId}/rows?worker=cf:1&after=0&limit=2000`));
  const fin = await handler(workerRequest("POST", `/backups/${backupId}/finalize`, {
    worker: "cf:1",
    recordCount: 595,
    byteSize: 40960,
    sha256: "a".repeat(64),
    files,
  }));
  assertEquals(fin.status, 200);
  await handler(
    workerRequest("POST", `/backups/${backupId}/fail`, { worker: "cf:1", reason: "timeout" }),
  );
  await handler(workerRequest("GET", "/backups/expired?limit=10"));
  await handler(workerRequest("POST", `/backups/${backupId}/deleted`, {}));
  await handler(workerRequest("GET", `/${backupId}/brand?worker=cf:1`));
  assertEquals(calls.map((c) => c.fn), [
    "backup_claim",
    "backup_prepare",
    "backup_rows",
    "backup_finalize",
    "backup_fail",
    "backup_expired",
    "backup_deleted",
    "export_brand",
  ]);
  assertEquals((calls[3]?.args.p_files as unknown[]).length, 35);
});

Deno.test("backup finalize checks every file entry", async () => {
  const { handler, calls } = worker();
  for (
    const bad of [
      [{ section: "people", rows: 1, sha256: "x" }],
      [{ section: "People", rows: 1, sha256: "d".repeat(64) }],
      [{ section: "people", rows: -1, sha256: "d".repeat(64) }],
      [{ section: "people", rows: 1, sha256: "d".repeat(64), path: "/etc" }],
      [],
    ]
  ) {
    const response = await handler(workerRequest("POST", `/backups/${backupId}/finalize`, {
      worker: "cf:1",
      recordCount: 1,
      byteSize: 10,
      sha256: "a".repeat(64),
      files: bad,
    }));
    assertEquals(await code(response), "validation_error");
  }
  const rows = await handler(
    workerRequest("GET", `/backups/${backupId}/rows?worker=cf:1&after=0&limit=2001`),
  );
  assertEquals(await code(rows), "validation_error");
  assertEquals(calls.length, 0);
});

// ── T02–T05 ──

Deno.test("T02–T05 follow Paper", () => {
  const ready = renderEmail("team.backup_ready", 1, {
    network: "Cedar Network",
    taken: "5 Oct 2026, 11:40",
    size: "48 MB",
    path: "/app/settings/backups",
  }, { appUrl });
  assert(ready.html.includes("Your team backup is ready."));
  assert(ready.html.includes("5 Oct 2026, 11:40 · 48 MB"));
  assert(ready.html.includes("root-backup-ready.png"));
  const failed = renderEmail("team.backup_failed", 1, {
    network: "Cedar Network",
    taken: "5 Oct 2026, 11:40",
    path: "/app/settings/backups",
  }, { appUrl });
  assert(failed.html.includes("Nothing was lost. Try again from the vault."));
  const review = renderEmail("team.restore_update", 1, {
    network: "Cedar Network",
    reference: "RST-2C9F-0107",
    status: "In review",
    path: "/app/settings/backups",
  }, { appUrl });
  assert(review.html.includes("Your restore request is in review."));
  assert(review.html.includes("RST-2C9F-0107"));
  const branding = renderEmail("team.branding_changed", 1, {
    network: "Cedar Network",
    actor: "Ifeoma O.",
    summary: "the logo and slogan",
    revision: "12",
    path: "/app/settings",
  }, { appUrl });
  assert(branding.html.includes("Ifeoma O. updated the logo and slogan."));
  assert(branding.html.includes("Logo and slogan updated"));
  assert(branding.html.includes("Revision 12"));
});

Deno.test("T04 and T05 refuse values outside their contract", () => {
  assertThrows(
    () =>
      renderEmail("team.restore_update", 1, {
        network: "Cedar Network",
        reference: "RST-2C9F-0107",
        status: "Done-ish",
        path: "/app/settings/backups",
      }, { appUrl }),
    TemplateError,
  );
  assertThrows(
    () =>
      renderEmail("team.branding_changed", 1, {
        network: "Cedar Network",
        actor: "Ifeoma O.",
        summary: "<b>everything</b>",
        revision: "12",
        path: "/app/settings",
      }, { appUrl }),
    TemplateError,
  );
  assertThrows(
    () =>
      renderEmail("team.backup_ready", 1, {
        network: "Cedar Network",
        taken: "5 Oct 2026, 11:40",
        size: "48 MB",
        path: "https://evil.example/app",
      }, { appUrl }),
    TemplateError,
  );
});
