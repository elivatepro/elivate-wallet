import { requireStepUpSession } from "../_shared/session.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { isUuid, mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";

type TeamConfigurationRequest = Readonly<{
  idempotencyKey: string;
  tenantId: string;
  sessionId: string;
  teamDisplayName: string;
  teamShortName: string | null;
  supportContactName: string | null;
  supportContactEmail: string | null;
  supportContactPhone: string | null;
  localeCode: string;
  timezoneName: string;
  primaryLogoAssetId: string | null;
  squareAppIconAssetId: string | null;
  lightLogoAssetId: string | null;
  darkLogoAssetId: string | null;
  themeKey: string | null;
  teamSlogan: string | null;
  supportUrl: string | null;
  revisionReason: string;
}>;

type CommandClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, string | null>>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
    >;
  }>;
}>;

function optionalString(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string") {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed;
}

function optionalUuid(value: unknown): string | null {
  const parsed = optionalString(value);
  if (parsed !== null && !isUuid(parsed)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return parsed;
}

function requiredString(value: unknown): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new DomainError("validation_error", "Request body is invalid");
  }
  return value.trim();
}

function parseBody(value: unknown): TeamConfigurationRequest {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }

  const body = value as Record<string, unknown>;
  const idempotencyKey = requiredString(body.idempotencyKey);
  const tenantId = requiredString(body.tenantId);
  const sessionId = requiredString(body.sessionId);
  if (!isUuid(idempotencyKey) || !isUuid(tenantId) || !isUuid(sessionId)) {
    throw new DomainError("validation_error", "Request body is invalid");
  }

  return {
    idempotencyKey,
    tenantId,
    sessionId,
    teamDisplayName: requiredString(body.teamDisplayName),
    teamShortName: optionalString(body.teamShortName),
    supportContactName: optionalString(body.supportContactName),
    supportContactEmail: optionalString(body.supportContactEmail),
    supportContactPhone: optionalString(body.supportContactPhone),
    localeCode: requiredString(body.localeCode),
    timezoneName: requiredString(body.timezoneName),
    primaryLogoAssetId: optionalUuid(body.primaryLogoAssetId),
    squareAppIconAssetId: optionalUuid(body.squareAppIconAssetId),
    lightLogoAssetId: optionalUuid(body.lightLogoAssetId),
    darkLogoAssetId: optionalUuid(body.darkLogoAssetId),
    themeKey: optionalString(body.themeKey),
    teamSlogan: optionalString(body.teamSlogan),
    supportUrl: optionalString(body.supportUrl),
    revisionReason: requiredString(body.revisionReason),
  };
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
      await authenticatedServiceSupabase(
        request,
      );
    const commandClient = client as unknown as CommandClient;
    const { data, error } = await commandClient.schema("command_api").rpc(
      "update_team_configuration",
      {
        p_idempotency_key: body.idempotencyKey,
        p_actor_user_id: userId,
        p_session_id: requireStepUpSession(stepUpSessionId),
        p_tenant_id: body.tenantId,
        p_team_display_name: body.teamDisplayName,
        p_team_short_name: body.teamShortName,
        p_support_contact_name: body.supportContactName,
        p_support_contact_email: body.supportContactEmail,
        p_support_contact_phone: body.supportContactPhone,
        p_locale_code: body.localeCode,
        p_timezone_name: body.timezoneName,
        p_primary_logo_asset_id: body.primaryLogoAssetId,
        p_square_app_icon_asset_id: body.squareAppIconAssetId,
        p_light_logo_asset_id: body.lightLogoAssetId,
        p_dark_logo_asset_id: body.darkLogoAssetId,
        p_theme_key: body.themeKey,
        p_team_slogan: body.teamSlogan,
        p_support_url: body.supportUrl,
        p_revision_reason: body.revisionReason,
      },
    );
    if (error !== null) throw mapDatabaseError(error);
    return successResponse(request, requestId, data);
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
