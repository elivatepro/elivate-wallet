import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import { invitationTokenDigest } from "../_shared/invitation.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";

type InvitationCommandClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, string | null>>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
    >;
  }>;
}>;

type InviteInput = {
  email: string;
  role: "member" | "team_leader";
  tenantId: string;
  officeId: string;
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function parseBody(value: unknown): InviteInput {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Invitation input is invalid");
  }
  const body = value as Record<string, unknown>;
  if (
    typeof body.email !== "string" ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(body.email) ||
    body.email.length > 254 ||
    (body.role !== "member" && body.role !== "team_leader") ||
    typeof body.tenantId !== "string" ||
    !uuid.test(body.tenantId) ||
    typeof body.officeId !== "string" ||
    !uuid.test(body.officeId)
  ) {
    throw new DomainError("validation_error", "Invitation input is invalid");
  }
  return {
    email: body.email.trim().toLowerCase(),
    role: body.role,
    tenantId: body.tenantId,
    officeId: body.officeId,
  };
}

function newToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

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
    const body = parseBody(await request.json());
    const { client, userId, stepUpSessionId } =
      await authenticatedServiceSupabase(request);
    const appOrigin = Deno.env.get("ELIVATE_APP_ORIGIN");
    if (!appOrigin || !appOrigin.startsWith("https://")) {
      throw new Error("Elivate app origin is not configured");
    }
    const token = newToken();
    const tokenDigest = await invitationTokenDigest(token);
    const commandClient = client as unknown as InvitationCommandClient;
    const { data: invitationId, error } = await commandClient.schema(
      "command_api",
    )
      .rpc(
        "create_invitation",
        {
          p_idempotency_key: crypto.randomUUID(),
          p_actor_user_id: userId,
          p_session_id: stepUpSessionId,
          p_tenant_id: body.tenantId,
          p_office_id: body.officeId,
          p_role_key: body.role,
          p_email: body.email,
          p_token_digest: tokenDigest,
          p_expires_at: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
        },
      );
    if (error) throw mapDatabaseError(error);
    const { data: tenant, error: tenantError } = await client.from("tenants")
      .select("name")
      .eq("id", body.tenantId)
      .single();
    if (tenantError || !tenant) {
      throw new Error("Invitation tenant could not be loaded");
    }
    const joinUrl = new URL("/join", appOrigin);
    joinUrl.searchParams.set("token", token);
    const confirmUrl = new URL("/auth/confirm", appOrigin);
    confirmUrl.searchParams.set(
      "next",
      `/complete-invitation?token=${encodeURIComponent(token)}`,
    );
    const { error: emailError } = await client.auth.admin.inviteUserByEmail(
      body.email,
      {
        redirectTo: confirmUrl.toString(),
        data: {
          workspace_name: tenant.name,
          invited_role: body.role === "team_leader" ? "Team Leader" : "Member",
        },
      },
    );
    return successResponse(request, requestId, {
      invitationId,
      joinUrl: joinUrl.toString(),
      emailSent: !emailError,
    });
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
