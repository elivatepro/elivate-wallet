import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { parseWithdrawalTargetQuery } from "../_shared/withdrawal-sources.ts";
import { mapDatabaseError } from "../_shared/financial.ts";
import { authenticatedServiceSupabase } from "../_shared/supabase.ts";

type WithdrawalCursor = Readonly<{
  createdAt: string;
  withdrawalId: string;
}>;

type ReadApiClient = Readonly<{
  schema: (name: string) => Readonly<{
    rpc: (
      name: string,
      args: Readonly<Record<string, string | number | null>>,
    ) => Promise<
      Readonly<
        {
          data: unknown;
          error: Readonly<{ message: string; code?: string }> | null;
        }
      >
    >;
  }>;
}>;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const encodeCursor = (cursor: WithdrawalCursor): string =>
  btoa(JSON.stringify(cursor))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");

const decodeCursor = (value: string): WithdrawalCursor => {
  try {
    const padded = value.replaceAll("-", "+").replaceAll("_", "/") + "===";
    const parsed: unknown = JSON.parse(
      atob(padded.slice(0, padded.length - (padded.length % 4))),
    );
    if (
      !isRecord(parsed) ||
      typeof parsed.createdAt !== "string" ||
      typeof parsed.withdrawalId !== "string" ||
      Number.isNaN(Date.parse(parsed.createdAt)) ||
      !uuidPattern.test(parsed.withdrawalId)
    ) {
      throw new DomainError("validation_error", "Withdrawal cursor is invalid");
    }
    return { createdAt: parsed.createdAt, withdrawalId: parsed.withdrawalId };
  } catch (error) {
    if (error instanceof DomainError) throw error;
    throw new DomainError("validation_error", "Withdrawal cursor is invalid");
  }
};

const parseLimit = (value: string | null): number => {
  if (value === null || value === "") return 50;
  const limit = Number(value);
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    throw new DomainError(
      "validation_error",
      "Withdrawal limit must be an integer between 1 and 100",
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
    const withdrawalId = parseWithdrawalTargetQuery(url.searchParams);
    if (withdrawalId !== null) {
      const readClient = client as unknown as ReadApiClient;
      const { data, error } = await readClient.schema("read_api").rpc(
        "member_withdrawal_target",
        {
          p_actor_user_id: userId,
          p_withdrawal_id: withdrawalId,
        },
      );
      if (error !== null) throw mapDatabaseError(error);
      return successResponse(request, requestId, data);
    }
    const cursorValue = url.searchParams.get("cursor");
    const cursor = cursorValue === null ? null : decodeCursor(cursorValue);
    const limit = parseLimit(url.searchParams.get("limit"));
    const readClient = client as unknown as ReadApiClient;
    const { data, error } = await readClient.schema("read_api").rpc(
      "member_withdrawals",
      {
        p_actor_user_id: userId,
        p_before_created_at: cursor?.createdAt ?? null,
        p_before_withdrawal_id: cursor?.withdrawalId ?? null,
        p_limit: limit,
        p_status: url.searchParams.get("status"),
      },
    );
    if (error !== null) throw error;
    if (!isRecord(data) || !Array.isArray(data.items)) {
      throw new DomainError(
        "internal_error",
        "Member withdrawals returned an invalid response",
      );
    }

    const databaseCursor = data.next_cursor;
    const nextCursor = isRecord(databaseCursor) &&
        typeof databaseCursor.created_at === "string" &&
        typeof databaseCursor.withdrawal_id === "string"
      ? encodeCursor({
        createdAt: databaseCursor.created_at,
        withdrawalId: databaseCursor.withdrawal_id,
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
