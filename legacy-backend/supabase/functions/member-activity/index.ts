import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";
import { DomainError } from "../../../src/shared/domain_error.ts";

type ActivityCursor = Readonly<{
  createdAt: string;
  entryId: string;
}>;

type ReadApiClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, string | number | null>>,
    ) => Promise<
      Readonly<{ data: unknown; error: Readonly<{ message: string }> | null }>
    >;
  }>;
}>;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const encodeCursor = (cursor: ActivityCursor): string =>
  btoa(JSON.stringify(cursor))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");

const decodeCursor = (value: string): ActivityCursor => {
  try {
    const padded = value.replaceAll("-", "+").replaceAll("_", "/") + "===";
    const parsed: unknown = JSON.parse(
      atob(padded.slice(0, padded.length - (padded.length % 4))),
    );
    if (
      !isRecord(parsed) ||
      typeof parsed.createdAt !== "string" ||
      typeof parsed.entryId !== "string" ||
      Number.isNaN(Date.parse(parsed.createdAt)) ||
      !uuidPattern.test(parsed.entryId)
    ) {
      throw new DomainError("validation_error", "Activity cursor is invalid");
    }
    return { createdAt: parsed.createdAt, entryId: parsed.entryId };
  } catch (error) {
    if (error instanceof DomainError) throw error;
    throw new DomainError("validation_error", "Activity cursor is invalid");
  }
};

const parseLimit = (value: string | null): number => {
  if (value === null || value === "") return 50;
  const limit = Number(value);
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    throw new DomainError(
      "validation_error",
      "Activity limit must be an integer between 1 and 100",
    );
  }
  return limit;
};

Deno.serve(async (request) => {
  const requestId = requestIdFor(request);
  if (request.method === "OPTIONS") return optionsResponse(request);
  if (request.method !== "GET") {
    return failureResponse(
      request,
      requestId,
      new DomainError("validation_error", "Method not allowed"),
    );
  }

  try {
    const { client, userId } = await authenticatedServiceSupabase(request);
    const url = new URL(request.url);
    const cursorValue = url.searchParams.get("cursor");
    const cursor = cursorValue === null ? null : decodeCursor(cursorValue);
    const limit = parseLimit(url.searchParams.get("limit"));
    const readClient = client as unknown as ReadApiClient;
    const { data, error } = await readClient.schema("read_api").rpc(
      "member_activity",
      {
        p_actor_user_id: userId,
        p_before_created_at: cursor?.createdAt ?? null,
        p_before_entry_id: cursor?.entryId ?? null,
        p_limit: limit,
        p_currency_code: url.searchParams.get("currency"),
        p_transaction_type: url.searchParams.get("type"),
        p_pocket_key: url.searchParams.get("pocket"),
      },
    );
    if (error !== null) throw error;
    if (!isRecord(data) || !Array.isArray(data.items)) {
      throw new DomainError(
        "internal_error",
        "Member activity returned an invalid response",
      );
    }

    const databaseCursor = data.next_cursor;
    const nextCursor = isRecord(databaseCursor) &&
        typeof databaseCursor.created_at === "string" &&
        typeof databaseCursor.entry_id === "string"
      ? encodeCursor({
        createdAt: databaseCursor.created_at,
        entryId: databaseCursor.entry_id,
      })
      : null;

    return successResponse(request, requestId, {
      items: data.items,
      nextCursor,
    });
  } catch (error) {
    return failureResponse(request, requestId, error);
  }
});
