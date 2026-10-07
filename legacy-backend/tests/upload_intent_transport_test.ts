import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { downloadAuthorizedUpload } from "../supabase/functions/_shared/upload-intent.ts";
import { DomainError } from "../src/shared/domain_error.ts";

const intentId = "91000000-0000-4000-8000-000000000701";
const actorId = "00000000-0000-4000-8000-000000000701";
const sessionId = "70000000-0000-4000-8000-000000000701";
const path =
  "10000000-0000-4000-8000-000000000701/91000000-0000-4000-8000-000000000701";

for (const kind of ["brand", "financial"] as const) {
  Deno.test(`${kind} denied lookup never accesses privileged Storage`, async () => {
    let downloads = 0;
    await assertRejects(
      () =>
        downloadAuthorizedUpload(
          {
            schema: () => ({
              rpc: () =>
                Promise.resolve({ data: null, error: { code: "42501" } }),
            }),
          },
          {
            from: () => ({
              download: () => {
                downloads++;
                return Promise.resolve({ data: new Blob(), error: null });
              },
            }),
          },
          kind,
          intentId,
          actorId,
          sessionId,
        ),
      DomainError,
      "You are not authorized",
    );
    assertEquals(downloads, 0);
  });
  Deno.test(`${kind} lookup passes verified identity before downloading the database path`, async () => {
    const events: string[] = [];
    const bucket = kind === "brand"
      ? "tenant-brand-assets"
      : "financial-evidence";
    const result = await downloadAuthorizedUpload(
      {
        schema: (schema) => {
          assertEquals(schema, "command_api");
          return {
            rpc: (name, args) => {
              assertEquals(
                name,
                kind === "brand"
                  ? "read_brand_asset_upload_intent"
                  : "read_financial_upload_intent",
              );
              assertEquals(args, {
                p_intent_id: intentId,
                p_actor_user_id: actorId,
                ...(kind === "brand" ? { p_session_id: sessionId } : {}),
              });
              events.push("authorize");
              return Promise.resolve({
                data: { storage_bucket_id: bucket, storage_object_path: path },
                error: null,
              });
            },
          };
        },
      },
      {
        from: (selectedBucket) => {
          assertEquals(selectedBucket, bucket);
          return {
            download: (selectedPath) => {
              assertEquals(selectedPath, path);
              events.push("download");
              return Promise.resolve({
                data: new Blob(["asset"]),
                error: null,
              });
            },
          };
        },
      },
      kind,
      intentId,
      actorId,
      sessionId,
    );
    assertEquals(events, ["authorize", "download"]);
    assertEquals(await result.text(), "asset");
  });
}

Deno.test("malformed database upload location fails before Storage", async () => {
  let downloads = 0;
  await assertRejects(
    () =>
      downloadAuthorizedUpload(
        {
          schema: () => ({
            rpc: () =>
              Promise.resolve({
                data: {
                  storage_bucket_id: "another-bucket",
                  storage_object_path: "../../secret",
                },
                error: null,
              }),
          }),
        },
        {
          from: () => ({
            download: () => {
              downloads++;
              return Promise.resolve({ data: new Blob(), error: null });
            },
          }),
        },
        "brand",
        intentId,
        actorId,
        sessionId,
      ),
    DomainError,
    "Upload intent response is invalid",
  );
  assertEquals(downloads, 0);
});
