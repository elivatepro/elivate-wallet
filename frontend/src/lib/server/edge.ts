// EdgeTransport (plan §5.2): the only way the app server talks to the Edge
// Functions. It adds the bearer token, the publishable key and X-Membership, and
// decodes every response (envelope, then route schema).

import { Context, Effect, Layer, Schema } from 'effect';
import type { BackendError, ContractViolation, TransportError } from '#lib/contract/errors.js';
import { COMMAND_TIMEOUT_MS, READ_TIMEOUT_MS, requestJson } from '#lib/contract/transport.js';

export type EdgeFunction = 'security' | 'org' | 'invitations';

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
	/** The signed-in user's access token (already verified by the caller). */
	readonly accessToken: string;
	readonly fetch: typeof globalThis.fetch;
	readonly signal?: AbortSignal;
}

export function makeEdgeTransport(options: EdgeTransportOptions): EdgeTransportShape {
	return {
		call: (call, schema) => {
			const url = new URL(`/functions/v1/${call.fn}${call.route.path}`, options.supabaseUrl);
			for (const [key, value] of Object.entries(call.query ?? {})) url.searchParams.set(key, value);
			const headers: Record<string, string> = {
				authorization: `Bearer ${options.accessToken}`,
				apikey: options.publishableKey
			};
			if (call.membershipId) headers['x-membership'] = call.membershipId;
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
