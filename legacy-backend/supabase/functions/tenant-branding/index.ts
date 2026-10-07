import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedSupabase } from "../_shared/supabase.ts";

type TenantBrandingRead = Readonly<{
  tenant_id: string;
  team_display_name: string;
  team_short_name: string | null;
  team_slogan: string | null;
  theme_key: string | null;
  support_url: string | null;
  primary_logo_asset_id: string | null;
  square_app_icon_asset_id: string | null;
  light_logo_asset_id: string | null;
  dark_logo_asset_id: string | null;
}>;

Deno.serve(async (request) => {
  const requestId = requestIdFor(request);
  if (request.method === "OPTIONS") return optionsResponse(request);
  if (request.method !== "GET") {
    return failureResponse(
      request,
      requestId,
      new Error("Method not allowed"),
    );
  }

  try {
    const { client } = await authenticatedSupabase(request);
    const { data, error } = await client
      .from("tenant_member_branding_read")
      .select(
        "tenant_id,team_display_name,team_short_name,team_slogan,theme_key,support_url,primary_logo_asset_id,square_app_icon_asset_id,light_logo_asset_id,dark_logo_asset_id",
      )
      .order("team_display_name", { ascending: true });

    if (error !== null) throw error;
    return successResponse(
      request,
      requestId,
      (data ?? []) as TenantBrandingRead[],
    );
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
