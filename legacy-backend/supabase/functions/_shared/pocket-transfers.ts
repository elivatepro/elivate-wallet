import { DomainError } from "../../../src/shared/domain_error.ts";
export type TransferClient = Readonly<
  {
    schema: (
      name: "read_api" | "command_api",
    ) => Readonly<
      {
        rpc: (
          name: string,
          args: Readonly<Record<string, unknown>>,
        ) => Promise<
          Readonly<{ data: unknown; error: Readonly<{ code?: string }> | null }>
        >;
      }
    >;
  }
>;
import { isUuid, mapDatabaseError } from "./financial.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "./http.ts";
type Authenticate = (
  request: Request,
) => Promise<
  { client: TransferClient; userId: string; stepUpSessionId: string | null }
>;
export type TransferOperation = "submit" | "approve" | "reject" | "cancel";
const invalid = () => {
  throw new DomainError("validation_error", "Transfer request is invalid");
};
function membership(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (!isUuid(value)) return invalid();
  return value;
}
function exact(value: Record<string, unknown>, keys: string[]) {
  if (
    Object.keys(value).some((key) => !keys.includes(key)) ||
    keys.some((key) => !Object.hasOwn(value, key))
  ) invalid();
}
export function parseTransferCommand(
  operation: TransferOperation,
  value: unknown,
) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return invalid();
  }
  const body = value as Record<string, unknown>;
  const keys = [
    "membershipId",
    "idempotencyKey",
    ...(operation === "submit"
      ? ["sourceLedgerAccountId", "destinationLedgerAccountId", "amount"]
      : operation === "approve"
      ? ["transferId"]
      : ["transferId", "reason"]),
  ];
  exact(body, keys);
  const selected = membership(body.membershipId);
  if (!isUuid(body.idempotencyKey)) return invalid();
  const args: Record<string, string | null> = {
    p_actor_membership_id: selected,
    p_idempotency_key: body.idempotencyKey,
  };
  if (operation === "submit") {
    if (
      !isUuid(body.sourceLedgerAccountId) ||
      !isUuid(body.destinationLedgerAccountId) ||
      typeof body.amount !== "string" ||
      !/^(?:0|[1-9]\d{0,19})(?:\.\d{1,18})?$/.test(body.amount) ||
      /^0(?:\.0+)?$/.test(body.amount)
    ) return invalid();
    Object.assign(args, {
      p_source_ledger_account_id: body.sourceLedgerAccountId,
      p_destination_ledger_account_id: body.destinationLedgerAccountId,
      p_amount: body.amount,
    });
  } else {
    if (!isUuid(body.transferId)) return invalid();
    args.p_transfer_id = body.transferId;
    if (operation !== "approve") {
      if (
        typeof body.reason !== "string" || !body.reason.trim() ||
        body.reason.trim().length > 500
      ) return invalid();
      args.p_reason = body.reason.trim();
    }
  }
  return args;
}
export function parseTransferQuery(
  query: URLSearchParams,
  choices = false,
): Record<string, string | null> {
  const allowed = choices
    ? ["membershipId", "afterLedgerAccountId", "sourceLedgerAccountId"]
    : [
      "membershipId",
      "status",
      "beforeCreatedAt",
      "beforeId",
      "transferId",
      "search",
    ];
  for (const key of query.keys()) {
    if (!allowed.includes(key) || query.getAll(key).length !== 1) invalid();
  }
  const args: Record<string, string | null> = {
    p_actor_membership_id: membership(query.get("membershipId")),
  };
  if (choices) {
    const after = query.get("afterLedgerAccountId"),
      source = query.get("sourceLedgerAccountId");
    if (
      (after !== null && !isUuid(after)) ||
      (source !== null && !isUuid(source)) ||
      (after !== null && source !== null)
    ) return invalid();
    return {
      ...args,
      p_after_ledger_account_id: after,
      p_source_ledger_account_id: source,
    };
  }
  const status = query.get("status"),
    before = query.get("beforeCreatedAt"),
    beforeId = query.get("beforeId"),
    target = query.get("transferId"),
    search = query.get("search")?.trim().replace(/\s+/g, " ") || null;
  if (
    (status !== null &&
      !["requested", "completed", "rejected", "cancelled"].includes(status)) ||
    (beforeId !== null && !isUuid(beforeId)) ||
    (target !== null && !isUuid(target)) ||
    (before === null) !== (beforeId === null) ||
    (before !== null &&
      (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/
        .test(before) || !Number.isFinite(Date.parse(before)))) ||
    (search !== null && search.length > 200) ||
    (target !== null && (status !== null || before !== null || search !== null))
  ) return invalid();
  return {
    ...args,
    p_status: status,
    p_before_created_at: before,
    p_before_transfer_id: beforeId,
    p_transfer_id: target,
    p_search: search,
  };
}
function protect(response: Response) {
  response.headers.set("Cache-Control", "no-store");
  response.headers.set("access-control-allow-methods", "GET, POST, OPTIONS");
  response.headers.set(
    "access-control-allow-headers",
    "authorization, apikey, content-type, x-request-id",
  );
  return response;
}
export async function handleTransferRead(
  request: Request,
  authenticate: Authenticate,
  choices = false,
): Promise<Response> {
  const requestId = requestIdFor(request);
  if (request.method === "OPTIONS") return protect(optionsResponse(request));
  try {
    if (request.method !== "GET") invalid();
    const query = parseTransferQuery(
      new URL(request.url).searchParams,
      choices,
    );
    const { client, userId } = await authenticate(request);
    const { data, error } = await client.schema("read_api").rpc(
      choices ? "pocket_transfer_choices" : "pocket_transfers",
      { ...query, p_actor_user_id: userId },
    );
    if (error) throw mapDatabaseError(error);
    return protect(successResponse(request, requestId, data));
  } catch (error) {
    return protect(failureResponse(request, requestId, error));
  }
}
export async function handleTransferCommand(
  request: Request,
  authenticate: Authenticate,
  operation: TransferOperation,
): Promise<Response> {
  const requestId = requestIdFor(request);
  if (request.method === "OPTIONS") return protect(optionsResponse(request));
  try {
    if (request.method !== "POST") invalid();
    const input = parseTransferCommand(operation, await request.json());
    const { client, userId, stepUpSessionId } = await authenticate(request);
    const { data, error } = await client.schema("command_api").rpc(
      `${operation}_pocket_transfer`,
      { ...input, p_actor_user_id: userId, p_session_id: stepUpSessionId },
    );
    if (error) throw mapDatabaseError(error);
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw Error("Transfer result unavailable");
    }
    const result = data as Record<string, unknown>;
    if (
      !isUuid(result.operation_id) ||
      typeof result.operation_reference !== "string" ||
      !result.operation_reference ||
      !["requested", "completed", "cancelled", "rejected"].includes(
        String(result.status),
      ) || typeof result.reused !== "boolean" ||
      (result.financial_transaction_id !== null &&
        !isUuid(result.financial_transaction_id)) ||
      ((result.status === "completed") !==
        (result.financial_transaction_id !== null)) ||
      (operation !== "submit" && result.operation_id !== input.p_transfer_id) ||
      (operation !== "submit" &&
        result.status !==
          ({
            approve: "completed",
            reject: "rejected",
            cancel: "cancelled",
          } as const)[operation]) ||
      (operation === "submit" && !result.reused &&
        result.status !== "requested")
    ) throw Error("Transfer result unavailable");
    return protect(successResponse(request, requestId, {
      operation_id: result.operation_id,
      operation_reference: result.operation_reference,
      status: result.status,
      financial_transaction_id: result.financial_transaction_id,
      reused: result.reused,
    }));
  } catch (error) {
    return protect(failureResponse(request, requestId, error));
  }
}
