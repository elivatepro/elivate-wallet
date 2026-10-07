import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import type { CommandClient } from "../_shared/command-client.ts";
import { parsePayoutDownload } from "../_shared/payout-evidence.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
Deno.serve(async (request) => {
  const requestId = requestIdFor(request);
  if (request.method === "OPTIONS") return optionsResponse(request);
  if (request.method !== "POST") {
    return failureResponse(
      request,
      requestId,
      new DomainError("validation_error", "Method not allowed"),
    );
  }
  try {
    const input = parsePayoutDownload(await request.json());
    const { client, userId } = await authenticatedServiceSupabase(request);
    const { data, error } = await (client as unknown as CommandClient).schema(
      "command_api",
    ).rpc("payout_evidence_download_object", {
      ...input,
      p_actor_user_id: userId,
    });
    if (error) throw mapDatabaseError(error);
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw new Error("Receipt is missing");
    }
    const object = data as Record<string, unknown>;
    if (
      object.bucket !== "financial-evidence" ||
      typeof object.path !== "string" || !object.path ||
      typeof object.originalFilename !== "string"
    ) throw new Error("Receipt location is invalid");
    const { data: signed, error: signError } = await client.storage.from(
      object.bucket,
    ).createSignedUrl(object.path, 60, { download: object.originalFilename });
    if (signError || !signed) throw new Error("Receipt could not be opened");
    return successResponse(request, requestId, {
      signedUrl: signed.signedUrl,
      expiresIn: 60,
    });
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
