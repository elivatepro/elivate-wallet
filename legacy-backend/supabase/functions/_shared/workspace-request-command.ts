import { DomainError } from "../../../src/shared/domain_error.ts";
import { mapDatabaseError } from "./financial.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "./http.ts";
import { authenticatedServiceSupabase } from "./supabase.ts";
import { objectBody, requiredString } from "./workspace-requests.ts";
type Extra = (
  body: Record<string, unknown>,
) => Record<string, unknown> | Promise<Record<string, unknown>>;
type RpcClient = {
  schema: (
    name: string,
  ) => {
    rpc: (
      name: string,
      args: Record<string, unknown>,
    ) => Promise<{ data: unknown; error: { code?: string } | null }>;
  };
};
export function workspaceRequestCommand(
  name: string,
  extra: Extra,
  returnToken = false,
): void {
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
      const b = objectBody(await request.json());
      const idempotencyKey = requiredString(b, "idempotencyKey"),
        membershipId = requiredString(b, "membershipId");
      if (returnToken) {
        const token = requiredString(b, "token");
        if (token.length < 32 || token.length > 256) {
          throw new DomainError("validation_error", "Entry token is invalid");
        }
      }
      const { client, userId, stepUpSessionId } =
        await authenticatedServiceSupabase(request);
      const { data, error } = await (client as unknown as RpcClient).schema(
        "command_api",
      ).rpc(
        name,
        {
          p_idempotency_key: idempotencyKey,
          p_actor_user_id: userId,
          p_session_id: stepUpSessionId,
          p_actor_membership_id: membershipId,
          ...await extra(b),
        },
      );
      if (error) throw mapDatabaseError(error);
      return successResponse(
        request,
        id,
        returnToken ? { id: data, token: b.token } : { id: data },
      );
    } catch (error) {
      return failureResponse(request, id, error);
    }
  });
}
