// EdgeTransport (plan §5.2): the only way the app server talks to the Edge
// Functions. It adds the bearer token, the publishable key and X-Membership, and
// decodes every response (envelope, then route schema).

import { Context, Effect, Layer, Schema } from 'effect';
import type { BackendError, ContractViolation, TransportError } from '#lib/contract/errors.js';
import { COMMAND_TIMEOUT_MS, READ_TIMEOUT_MS, requestJson } from '#lib/contract/transport.js';

export type EdgeFunction =
	'security' | 'org' | 'invitations' | 'identity' | 'payout' | 'ledger' | 'billing';

export interface EdgeRoute {
	readonly method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
	readonly path: string;
}

export interface EdgeCall {
	readonly fn: EdgeFunction;
	readonly route: EdgeRoute;
	readonly body?: unknown;
	readonly query?: Readonly<Record<string, string>>;
	readonly membershipId?: string;
	/** Blueprint 14: the app-server-only secret for routes that require it. */
	readonly appServerSecret?: string;
}

export type EdgeFailure = BackendError | TransportError | ContractViolation;

export interface EdgeTransportShape {
	readonly call: <S extends Schema.ConstraintDecoder<unknown>>(
		call: EdgeCall,
		schema: S
	) => Effect.Effect<S['Type'], EdgeFailure>;
}

export class EdgeTransport extends Context.Service<EdgeTransport, EdgeTransportShape>()(
	'EdgeTransport'
) {}

export interface EdgeTransportOptions {
	readonly supabaseUrl: string;
	readonly publishableKey: string;
	/**
	 * The signed-in user's access token (already verified by the caller), or
	 * null for the public invitation routes (preview, verify-email).
	 */
	readonly accessToken: string | null;
	readonly fetch: typeof globalThis.fetch;
	readonly signal?: AbortSignal;
}

export function makeEdgeTransport(options: EdgeTransportOptions): EdgeTransportShape {
	return {
		call: (call, schema) => {
			const url = new URL(`/functions/v1/${call.fn}${call.route.path}`, options.supabaseUrl);
			for (const [key, value] of Object.entries(call.query ?? {})) url.searchParams.set(key, value);
			const headers: Record<string, string> = { apikey: options.publishableKey };
			if (options.accessToken) headers.authorization = `Bearer ${options.accessToken}`;
			if (call.membershipId) headers['x-membership'] = call.membershipId;
			if (call.appServerSecret) headers['x-app-server-secret'] = call.appServerSecret;
			return requestJson(
				{
					fetch: options.fetch,
					url: url.toString(),
					method: call.route.method,
					route: `${call.route.method} /${call.fn}${call.route.path}`,
					headers,
					body: call.body,
					timeoutMs: call.route.method === 'GET' ? READ_TIMEOUT_MS : COMMAND_TIMEOUT_MS,
					signal: options.signal
				},
				schema
			);
		}
	};
}

export const EdgeTransportLive = (options: EdgeTransportOptions) =>
	Layer.succeed(EdgeTransport, makeEdgeTransport(options));
