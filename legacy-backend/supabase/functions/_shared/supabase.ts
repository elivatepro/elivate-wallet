import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.45.4";
import type { Database } from "../../../src/generated/database.types.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";
import { verifySession } from "./session.ts";

export type AuthenticatedSupabase = Readonly<{
  client: SupabaseClient<Database>;
  userId: string;
  sessionId: string;
  stepUpSessionId: string | null;
}>;

async function verifiedSession(
  request: Request,
  supabaseUrl: string,
  publishableKey: string,
): Promise<
  Readonly<
    { userId: string; sessionId: string; stepUpSessionId: string | null }
  >
> {
  const authorization = request.headers.get("authorization");
  if (authorization === null || !/^Bearer\s+\S+$/i.test(authorization)) {
    throw new DomainError(
      "authentication_required",
      "Authentication is required",
    );
  }

  const accessToken = authorization.replace(/^Bearer\s+/i, "");
  const client = createClient(supabaseUrl, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: authorization } },
  });
  return await verifySession(accessToken, async (exactToken) => {
    const { data, error } = await client.auth.getUser(exactToken);
    return error !== null || data.user === null ? null : data.user.id;
  });
}

function runtimeConfig(): Readonly<{
  supabaseUrl: string;
  publishableKey: string;
}> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publishableKey = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
    Deno.env.get("SUPABASE_ANON_KEY");
  if (supabaseUrl === undefined || publishableKey === undefined) {
    throw new Error("Supabase runtime configuration is incomplete");
  }
  return { supabaseUrl, publishableKey };
}

export async function authenticatedSupabase(
  request: Request,
): Promise<AuthenticatedSupabase> {
  const { supabaseUrl, publishableKey } = runtimeConfig();
  const authorization = request.headers.get("authorization");
  if (authorization === null || !/^Bearer\s+\S+$/i.test(authorization)) {
    throw new DomainError(
      "authentication_required",
      "Authentication is required",
    );
  }
  const identity = await verifiedSession(request, supabaseUrl, publishableKey);
  const client = createClient<Database>(supabaseUrl, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: authorization } },
  });
  return { client, ...identity };
}

export async function authenticatedServiceSupabase(
  request: Request,
): Promise<AuthenticatedSupabase> {
  const { supabaseUrl, publishableKey } = runtimeConfig();
  const identity = await verifiedSession(request, supabaseUrl, publishableKey);
  const secretKey = Deno.env.get("SUPABASE_SECRET_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (secretKey === undefined) {
    throw new Error("Supabase trusted runtime configuration is incomplete");
  }
  return {
    client: createClient<Database>(supabaseUrl, secretKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    }),
    ...identity,
  };
}
