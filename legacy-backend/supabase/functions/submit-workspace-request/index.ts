import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { DomainError } from "../../../src/shared/domain_error.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import {
  objectBody,
  requiredString,
  sha256,
} from "../_shared/workspace-requests.ts";
Deno.serve(async (request) => {
  const id = requestIdFor(request);
  if (request.method === "OPTIONS") return optionsResponse(request);
  if (request.method !== "POST") {
    return failureResponse(
      request,
      id,
      new DomainError("validation_error", "Method not allowed"),
    );
  }
  try {
    const b = objectBody(await request.json()),
      token = requiredString(b, "entryToken");
    if (token.length < 32 || token.length > 256) {
      throw new DomainError(
        "validation_error",
        "Workspace request input is invalid",
      );
    }
    const url = Deno.env.get("SUPABASE_URL"),
      key = Deno.env.get("SUPABASE_SECRET_KEY") ??
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) {
      throw new Error("Workspace request runtime is not configured");
    }
    const { data, error } = await createClient(url, key, {
      auth: { autoRefreshToken: false, persistSession: false },
    }).schema("command_api").rpc("submit_workspace_request", {
      p_idempotency_key: requiredString(b, "idempotencyKey"),
      p_tenant_id: requiredString(b, "tenantId"),
      p_entry_token_digest: await sha256(token),
      p_full_name: requiredString(b, "fullName"),
      p_email: requiredString(b, "email"),
      p_phone: requiredString(b, "phone"),
      p_team_name: requiredString(b, "teamName"),
      p_rank: requiredString(b, "rank"),
    });
    if (error) throw mapDatabaseError(error);
    return successResponse(request, id, { request_id: data });
  } catch (error) {
    return failureResponse(request, id, error);
  }
});
