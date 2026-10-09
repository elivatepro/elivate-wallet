// Routes for the `billing` Edge Function (Blueprint 16 — B3). Deployed with
// verify_jwt = false: the Paystack webhook is authenticated by its signature,
// the sync worker by BILLING_WORKER_SECRET, and user routes verify the bearer
// token here. Payment truth is always Paystack's server-side verification,
// never a client redirect.

import {
  ApiError,
  corsHeaders,
  type Details,
  failure,
  isErrorCode,
  success,
} from "../_shared/http.ts";
import {
  type PaystackBilling,
  referencePattern,
  sha256Hex,
  validSignature,
  type VerifiedCharge,
} from "../_shared/paystack_billing.ts";
import { sameSecret } from "../_shared/secret.ts";
import * as v from "../_shared/validate.ts";

export interface Actor {
  readonly userId: string;
  readonly sessionId: string;
}

export type RpcResult =
  | { readonly data: unknown; readonly error: null }
  | {
    readonly data: null;
    readonly error: { readonly message: string; readonly details?: string | null };
  };

export interface LogEntry {
  readonly requestId: string;
  readonly route: string;
  readonly status: number;
  readonly code?: string;
  readonly outcome?: string;
  /** Internal errors only: which step failed (never request data or secrets). */
  readonly cause?: string;
  readonly ms: number;
}

export interface Deps {
  verifyToken(token: string): Promise<Actor | null>;
  rpc(fn: string, args: Record<string, unknown>): Promise<RpcResult>;
  log(entry: LogEntry): void;
  readonly allowedOrigins: readonly string[];
  /** Null when PAYSTACK_SECRET_KEY is missing: payments answer provider_unavailable. */
  readonly paystack: PaystackBilling | null;
  /** The webhook HMAC key (PAYSTACK_SECRET_KEY). */
  readonly webhookSecret: string | null;
  readonly workerSecret: string | null;
  /** Where Paystack sends the payer back, e.g. https://app.elivatewallet.com. */
  readonly appOrigin: string | null;
  readonly now?: () => Date;
}

interface Context {
  readonly request: Request;
  readonly actor: Actor;
  readonly requestId: string;
  readonly params: Readonly<Record<string, string>>;
  readonly query: URLSearchParams;
}

type Json = Readonly<Record<string, unknown>>;
type Handler = (context: Context) => Promise<unknown>;

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const planKeys = ["band_400", "band_1000", "band_1001_plus"] as const;
const maxWebhookBytes = 64 * 1024;

function parseDetails(raw: string | null | undefined): Details {
  if (!raw) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
      ? parsed as Details
      : {};
  } catch {
    return {};
  }
}

function object(value: unknown): Json | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Json
    : null;
}

function match(pattern: string, path: string): Record<string, string> | null {
  const want = pattern.split("/");
  const got = path.split("/");
  if (want.length !== got.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < want.length; i++) {
    const w = want[i] ?? "";
    const g = got[i] ?? "";
    if (w.startsWith(":")) {
      if (!uuidPattern.test(g)) return null;
      params[w.slice(1)] = g.toLowerCase();
    } else if (w !== g) {
      return null;
    }
  }
  return params;
}

function workspace(request: Request): string {
  const value = request.headers.get("x-membership");
  if (!value || !uuidPattern.test(value)) throw new ApiError("workspace_invalid");
  return value.toLowerCase();
}

function onlyQuery(query: URLSearchParams, allowed: readonly string[]): void {
  for (const key of query.keys()) {
    if (!allowed.includes(key)) {
      throw new ApiError("validation_error", { field: key, reason: "unknown_field" });
    }
  }
}

function planKey(body: v.Body, field = "planKey"): string {
  const value = body[field];
  if (typeof value !== "string" || !(planKeys as readonly string[]).includes(value)) {
    throw new ApiError("validation_error", { field });
  }
  return value;
}

/** Strips server-only fields before anything reaches the client. */
function publicCheckout(result: Json): Json {
  return {
    paymentId: result.paymentId ?? null,
    applied: result.applied === true,
    reference: result.reference ?? null,
    amount: result.amount ?? null,
    currency: result.currency ?? null,
    status: result.status ?? null,
    authorizationUrl: result.authorizationUrl ?? null,
  };
}

export function createHandler(deps: Deps): (request: Request) => Promise<Response> {
  const now = deps.now ?? (() => new Date());

  async function rpc(fn: string, args: Record<string, unknown>): Promise<unknown> {
    const { data, error } = await deps.rpc(fn, args);
    if (error) {
      if (isErrorCode(error.message)) {
        throw new ApiError(error.message, parseDetails(error.details));
      }
      // The database message names the failing statement, never secrets.
      throw new Error(`rpc ${fn} failed: ${error.message.slice(0, 160)}`);
    }
    return data;
  }
  async function call(fn: string, args: Record<string, unknown>): Promise<Json> {
    const data = object(await rpc(fn, args));
    if (!data) throw new Error("unexpected result shape");
    return data;
  }

  const actorArgs = ({ actor }: Context) => ({
    p_user_id: actor.userId,
    p_session_id: actor.sessionId,
  });
  const inWorkspace = (c: Context) => ({ ...actorArgs(c), p_membership_id: workspace(c.request) });

  function provider(): PaystackBilling {
    if (!deps.paystack) throw new ApiError("provider_unavailable");
    return deps.paystack;
  }

  /** Applies a charge Paystack confirmed as successful, by its own reference. */
  function applyVerified(charge: VerifiedCharge): Promise<Json> {
    return call("billing_apply_verified", {
      p_provider_reference: charge.reference,
      p_amount_kobo: charge.amountKobo,
      p_currency: charge.currency,
      p_paid_at: charge.paidAt ?? now().toISOString(),
      p_transaction_id: charge.transactionId,
      p_customer_code: charge.customerCode,
      p_reusable: charge.reusable,
      p_environment: charge.environment ?? "unknown",
    });
  }

  function recordRenewal(
    charge: VerifiedCharge,
    subscriptionCode: string | null,
  ): Promise<Json> {
    return call("billing_record_renewal", {
      p_provider_reference: charge.reference,
      p_subscription_code: subscriptionCode,
      p_customer_code: charge.customerCode,
      p_plan_code: charge.planCode,
      p_amount_kobo: charge.amountKobo,
      p_currency: charge.currency,
      p_paid_at: charge.paidAt ?? now().toISOString(),
      p_transaction_id: charge.transactionId,
      p_reusable: charge.reusable,
      p_environment: charge.environment ?? "unknown",
    });
  }

  // ── User routes ──────────────────────────────────────────────────────────

  const routes: { method: string; pattern: string; handler: Handler }[] = [
    {
      method: "GET",
      pattern: "/setup",
      handler: (c) => {
        onlyQuery(c.query, []);
        return call("billing_setup", actorArgs(c));
      },
    },
    {
      method: "GET",
      pattern: "/overview",
      handler: (c) => {
        onlyQuery(c.query, []);
        return call("billing_overview", inWorkspace(c));
      },
    },
    {
      method: "POST",
      pattern: "/checkout",
      handler: async (c) => {
        const body = await v.readBody(c.request, ["planKey", "kind", "returnTo", "idempotencyKey"]);
        const kind = body.kind;
        if (kind !== "year" && kind !== "upgrade") {
          throw new ApiError("validation_error", { field: "kind" });
        }
        const returnTo = body.returnTo ?? "billing";
        if (returnTo !== "billing" && returnTo !== "setup") {
          throw new ApiError("validation_error", { field: "returnTo" });
        }
        const paystack = provider();
        if (!deps.appOrigin) throw new ApiError("provider_unavailable");
        const result = await call("billing_checkout", {
          ...inWorkspace(c),
          p_plan_key: planKey(body),
          p_kind: kind,
          p_environment: paystack.environment,
          p_idempotency_key: v.idempotencyKey(body),
          p_request_id: c.requestId,
        });
        if (result.applied === true || result.status !== "open" || result.authorizationUrl) {
          return publicCheckout(result);
        }
        const paymentId = String(result.paymentId);
        const path = returnTo === "setup" ? "/setup/payment/" : "/app/billing/payments/";
        const opened = await paystack.initialize({
          email: String(result.email),
          amountKobo: Number(result.amountKobo),
          reference: String(result.providerReference),
          callbackUrl: `${deps.appOrigin}${path}${paymentId}`,
          paymentId,
        });
        if (opened.kind !== "ok") throw new ApiError("provider_unavailable");
        await call("billing_checkout_opened", {
          p_user_id: c.actor.userId,
          p_payment_id: paymentId,
          p_authorization_url: opened.authorizationUrl,
        });
        return publicCheckout({ ...result, authorizationUrl: opened.authorizationUrl });
      },
    },
    {
      method: "GET",
      pattern: "/payments/:id",
      handler: async (c) => {
        onlyQuery(c.query, ["returned"]);
        const args = { ...inWorkspace(c), p_payment_id: c.params.id };
        let result = await call("billing_payment", args);
        const verify = object(result.verify);
        const reference = typeof verify?.providerReference === "string"
          ? verify.providerReference
          : null;
        if (reference && deps.paystack) {
          // Checked with Paystack server-side; the redirect itself proves nothing.
          const charge = await deps.paystack.verify(reference);
          if (charge.kind === "ok" && charge.reference === reference) {
            if (charge.status === "success") {
              await applyVerified(charge);
            } else if (
              charge.status === "failed" ||
              (charge.status === "abandoned" && c.query.get("returned") === "1")
            ) {
              await call("billing_mark_unpaid", {
                p_provider_reference: reference,
                p_status: charge.status,
              });
            }
            result = await call("billing_payment", args);
          }
        }
        return { payment: result.payment, tenantStatus: result.tenantStatus };
      },
    },
    {
      method: "POST",
      pattern: "/auto-renew",
      handler: async (c) => {
        const body = await v.readBody(c.request, ["enabled", "idempotencyKey"]);
        if (typeof body.enabled !== "boolean") {
          throw new ApiError("validation_error", { field: "enabled" });
        }
        return call("billing_set_auto_renew", {
          ...inWorkspace(c),
          p_enabled: body.enabled,
          p_idempotency_key: v.idempotencyKey(body),
          p_request_id: c.requestId,
        });
      },
    },
    {
      method: "POST",
      pattern: "/next-plan",
      handler: async (c) => {
        const body = await v.readBody(c.request, ["planKey", "idempotencyKey"]);
        return call("billing_set_next_plan", {
          ...inWorkspace(c),
          p_plan_key: body.planKey === null ? null : planKey(body),
          p_idempotency_key: v.idempotencyKey(body),
          p_request_id: c.requestId,
        });
      },
    },
    {
      method: "GET",
      pattern: "/owner-candidates",
      handler: async (c) => {
        onlyQuery(c.query, ["q"]);
        const q = c.query.get("q");
        if (q !== null && q.length > 100) throw new ApiError("validation_error", { field: "q" });
        return {
          candidates: await rpc("billing_owner_candidates", { ...inWorkspace(c), p_query: q }),
        };
      },
    },
    {
      method: "POST",
      pattern: "/owner",
      handler: async (c) => {
        const body = await v.readBody(c.request, ["membershipId", "idempotencyKey"]);
        return call("change_billing_owner", {
          ...inWorkspace(c),
          p_target_membership_id: v.uuid(body, "membershipId"),
          p_idempotency_key: v.idempotencyKey(body),
          p_request_id: c.requestId,
        });
      },
    },
  ];

  // ── Paystack webhook ─────────────────────────────────────────────────────

  async function readRaw(request: Request): Promise<Uint8Array<ArrayBuffer>> {
    const declared = Number(request.headers.get("content-length") ?? "0");
    if (declared > maxWebhookBytes) throw new ApiError("validation_error", { field: "body" });
    const raw = new Uint8Array(await request.arrayBuffer());
    if (raw.byteLength === 0 || raw.byteLength > maxWebhookBytes) {
      throw new ApiError("validation_error", { field: "body" });
    }
    return raw;
  }

  /** Returns the outcome; throws on transient failures so Paystack retries. */
  async function webhook(
    event: string,
    data: Json,
  ): Promise<{ outcome: string; tenantId?: unknown; paymentId?: unknown }> {
    if (event === "charge.success") {
      const reference = typeof data.reference === "string" && referencePattern.test(data.reference)
        ? data.reference
        : null;
      if (!reference) return { outcome: "bad_reference" };
      const charge = await provider().verify(reference);
      if (charge.kind === "unavailable") throw new Error("verify unavailable");
      if (charge.kind === "not_found" || charge.reference !== reference) {
        return { outcome: "not_verified" };
      }
      if (charge.status !== "success") return { outcome: "not_successful" };
      const applied = await applyVerified(charge);
      if (applied.outcome === "unknown_reference" && charge.planCode) {
        const renewal = await recordRenewal(charge, null);
        return {
          outcome: String(renewal.outcome),
          tenantId: renewal.tenantId,
          paymentId: renewal.paymentId,
        };
      }
      return {
        outcome: String(applied.outcome),
        tenantId: applied.tenantId,
        paymentId: applied.paymentId,
      };
    }
    if (event === "invoice.update" || event === "invoice.create") {
      const transaction = object(data.transaction);
      const subscription = object(data.subscription);
      const reference =
        typeof transaction?.reference === "string" && referencePattern.test(transaction.reference)
          ? transaction.reference
          : null;
      const paid = data.paid === true || data.status === "success" ||
        transaction?.status === "success";
      if (!reference || !paid) return { outcome: "not_paid" };
      const charge = await provider().verify(reference);
      if (charge.kind === "unavailable") throw new Error("verify unavailable");
      if (
        charge.kind === "not_found" || charge.reference !== reference || charge.status !== "success"
      ) {
        return { outcome: "not_verified" };
      }
      const code = typeof subscription?.subscription_code === "string"
        ? subscription.subscription_code
        : null;
      const renewal = await recordRenewal(charge, code);
      return {
        outcome: String(renewal.outcome),
        tenantId: renewal.tenantId,
        paymentId: renewal.paymentId,
      };
    }
    if (
      event === "subscription.create" || event === "subscription.disable" ||
      event === "subscription.not_renew"
    ) {
      const code = typeof data.subscription_code === "string" ? data.subscription_code : null;
      if (!code || !/^SUB_[A-Za-z0-9]{1,60}$/.test(code)) return { outcome: "bad_subscription" };
      const result = await call("billing_provider_subscription", {
        p_event: event,
        p_subscription_code: code,
        p_email_token: typeof data.email_token === "string" ? data.email_token : null,
      });
      return { outcome: String(result.outcome), tenantId: result.tenantId };
    }
    if (event === "invoice.payment_failed") return { outcome: "payment_failed" };
    return { outcome: "ignored" };
  }

  async function handleWebhook(
    request: Request,
    requestId: string,
  ): Promise<{ response: Response; outcome?: string }> {
    if (!deps.webhookSecret) return { response: failure("internal_error", requestId) };
    let raw: Uint8Array<ArrayBuffer>;
    try {
      raw = await readRaw(request);
    } catch {
      return { response: failure("validation_error", requestId) };
    }
    // The signature is checked over the raw bytes before anything is parsed.
    if (
      !(await validSignature(raw, request.headers.get("x-paystack-signature"), deps.webhookSecret))
    ) {
      return { response: failure("authentication_required", requestId), outcome: "bad_signature" };
    }
    let payload: Json | null;
    try {
      payload = object(JSON.parse(new TextDecoder().decode(raw)));
    } catch {
      payload = null;
    }
    const event = typeof payload?.event === "string" ? payload.event : null;
    const data = object(payload?.data);
    if (!event || event.length > 60 || !data) {
      return { response: success({ received: true }, requestId), outcome: "malformed" };
    }
    const id = typeof data.id === "number" || typeof data.id === "string" ? String(data.id) : null;
    const anchor = id ?? (typeof data.reference === "string" ? data.reference : null) ??
      (typeof data.subscription_code === "string" ? data.subscription_code : null);
    const sha = await sha256Hex(raw);
    const recorded = await call("billing_record_event", {
      p_dedupe_key: `${event}:${anchor ?? sha}`.slice(0, 200),
      p_event: event,
      p_body_sha256: sha,
    });
    if (recorded.duplicate === true) {
      return {
        response: success({ received: true, duplicate: true }, requestId),
        outcome: "duplicate",
      };
    }
    const result = await webhook(event, data);
    await call("billing_event_done", {
      p_event_id: recorded.eventId,
      p_outcome: result.outcome.slice(0, 40),
      p_tenant_id: typeof result.tenantId === "string" ? result.tenantId : null,
      p_payment_id: typeof result.paymentId === "string" ? result.paymentId : null,
    });
    return { response: success({ received: true }, requestId), outcome: result.outcome };
  }

  // ── Subscription sync worker ─────────────────────────────────────────────

  async function syncSubscriptions(): Promise<Json> {
    const paystack = provider();
    const plans =
      (await rpc("billing_plan_codes", { p_environment: paystack.environment })) as unknown[];
    const codes = new Map<string, string>();
    for (const item of Array.isArray(plans) ? plans : []) {
      const plan = object(item);
      if (!plan) continue;
      let code = typeof plan.planCode === "string" ? plan.planCode : null;
      if (!code) {
        const created = await paystack.createPlan(
          `Elivate Wallet — ${String(plan.name)} (yearly)`,
          Number(plan.amountKobo),
        );
        if (created) {
          const stored = await call("billing_set_plan_code", {
            p_plan_id: plan.planId,
            p_environment: paystack.environment,
            p_plan_code: created,
          });
          code = typeof stored.planCode === "string" ? stored.planCode : created;
        }
      }
      if (code) codes.set(String(plan.planId), code);
    }

    const jobs = await rpc("billing_sync_claim", { p_limit: 10 });
    let done = 0;
    let failed = 0;
    for (const item of Array.isArray(jobs) ? jobs : []) {
      const job = object(item);
      if (!job) continue;
      const tenantId = job.tenantId;
      try {
        if (typeof job.subscriptionCode === "string" && typeof job.emailToken === "string") {
          if (!(await paystack.disableSubscription(job.subscriptionCode, job.emailToken))) {
            throw new Error("disable failed");
          }
        }
        if (job.renew === true) {
          const planCode = codes.get(String(job.planId));
          if (
            !planCode || typeof job.customerCode !== "string" || typeof job.startDate !== "string"
          ) {
            throw new Error("sync input missing");
          }
          // Never in the past: a renewal due within the hour charges in an hour.
          const start = new Date(Math.max(Date.parse(job.startDate), now().getTime() + 3600_000));
          const created = await paystack.createSubscription({
            customerCode: job.customerCode,
            planCode,
            startDate: start.toISOString(),
          });
          if (created.kind === "unavailable") throw new Error("create failed");
          await call(
            "billing_sync_done",
            created.kind === "no_card" ? { p_tenant_id: tenantId, p_outcome: "no_card" } : {
              p_tenant_id: tenantId,
              p_outcome: "ok",
              p_subscription_code: created.subscriptionCode,
              p_email_token: created.emailToken,
              p_plan_code: planCode,
            },
          );
        } else {
          await call("billing_sync_done", { p_tenant_id: tenantId, p_outcome: "ok" });
        }
        done++;
      } catch {
        failed++;
        await call("billing_sync_done", { p_tenant_id: tenantId, p_outcome: "failed" });
      }
    }
    return { done, failed };
  }

  // ── Dispatch ─────────────────────────────────────────────────────────────

  return async (request: Request): Promise<Response> => {
    const started = Date.now();
    const requestId = crypto.randomUUID();
    const url = new URL(request.url);
    const path = url.pathname.replace(/^.*?\/billing(?=\/|$)/, "") || "/";
    const log = (route: string, response: Response, code?: string, outcome?: string) => {
      deps.log({
        requestId,
        route,
        status: response.status,
        ...(code ? { code } : {}),
        ...(outcome ? { outcome } : {}),
        ms: Date.now() - started,
      });
      return response;
    };

    if (path === "/paystack/webhook") {
      if (request.method !== "POST") {
        return log("webhook", failure("not_found", requestId), "not_found");
      }
      try {
        const { response, outcome } = await handleWebhook(request, requestId);
        return log("POST /paystack/webhook", response, undefined, outcome);
      } catch {
        // Transient (verification or database): Paystack retries the event.
        return log(
          "POST /paystack/webhook",
          failure("internal_error", requestId),
          "internal_error",
        );
      }
    }

    if (path === "/worker/sync") {
      if (request.method !== "POST") {
        return log("worker", failure("not_found", requestId), "not_found");
      }
      const token = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1] ?? "";
      if (!deps.workerSecret || !(await sameSecret(token, deps.workerSecret))) {
        return log(
          "POST /worker/sync",
          failure("authentication_required", requestId),
          "authentication_required",
        );
      }
      try {
        return log("POST /worker/sync", success(await syncSubscriptions(), requestId));
      } catch (error) {
        const code = error instanceof ApiError ? error.code : "internal_error";
        return log("POST /worker/sync", failure(code, requestId), code);
      }
    }

    const cors = corsHeaders(request.headers.get("origin"), deps.allowedOrigins);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    let found: { handler: Handler; name: string; params: Record<string, string> } | null = null;
    for (const candidate of routes) {
      if (candidate.method !== request.method) continue;
      const params = match(candidate.pattern, path);
      if (params) {
        found = {
          handler: candidate.handler,
          name: `${candidate.method} ${candidate.pattern}`,
          params,
        };
        break;
      }
    }
    if (!found) return log("unknown", failure("not_found", requestId, {}, cors), "not_found");

    try {
      const token = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
      const actor = token ? await deps.verifyToken(token) : null;
      if (!actor) throw new ApiError("authentication_required");
      const data = await found.handler({
        request,
        actor,
        requestId,
        params: found.params,
        query: url.searchParams,
      });
      return log(found.name, success(data, requestId, cors));
    } catch (error) {
      if (error instanceof ApiError) {
        return log(found.name, failure(error.code, requestId, error.details, cors), error.code);
      }
      deps.log({
        requestId,
        route: found.name,
        status: 500,
        code: "internal_error",
        cause: error instanceof Error ? error.message.slice(0, 200) : "unknown",
        ms: Date.now() - started,
      });
      return failure("internal_error", requestId, {}, cors);
    }
  };
}
