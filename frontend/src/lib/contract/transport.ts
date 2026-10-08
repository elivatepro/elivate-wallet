// One JSON request → typed result. Shared by the app server (→ Edge Functions)
// and the browser (→ same-origin JSON endpoints). Not Effect's HTTP module, which
// is still marked unstable in effect 4.0.x (plan §2).

import { Effect, Schema } from 'effect';
import { decodeResponse } from './envelope';
import { BackendError, ContractViolation, TransportError } from './errors';

export interface JsonRequest {
	readonly fetch: typeof globalThis.fetch;
	readonly url: string;
	readonly method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
	/** Route pattern for logs/errors only, never the concrete URL. */
	readonly route: string;
	readonly headers?: Readonly<Record<string, string>>;
	readonly body?: unknown;
	readonly timeoutMs: number;
	/** Caller's signal (navigation/request cancelled). */
	readonly signal?: AbortSignal;
}

export const READ_TIMEOUT_MS = 10_000;
export const COMMAND_TIMEOUT_MS = 20_000;

export function requestJson<S extends Schema.ConstraintDecoder<unknown>>(
	request: JsonRequest,
	schema: S
): Effect.Effect<S['Type'], BackendError | TransportError | ContractViolation> {
	return Effect.gen(function* () {
		const timeout = AbortSignal.timeout(request.timeoutMs);
		const signal = request.signal ? AbortSignal.any([request.signal, timeout]) : timeout;
		const headers: Record<string, string> = { accept: 'application/json', ...request.headers };
		if (request.body !== undefined) headers['content-type'] = 'application/json';

		const response = yield* Effect.tryPromise({
			try: () =>
				request.fetch(request.url, {
					method: request.method,
					headers,
					body: request.body === undefined ? undefined : JSON.stringify(request.body),
					signal,
					redirect: 'error',
					cache: 'no-store'
				}),
			catch: () =>
				new TransportError({
					reason: timeout.aborted ? 'timeout' : request.signal?.aborted ? 'aborted' : 'network',
					status: null
				})
		});

		const text = yield* Effect.tryPromise({
			try: () => response.text(),
			catch: () => new TransportError({ reason: 'network', status: response.status })
		});
		let body: unknown = undefined;
		try {
			body = text === '' ? undefined : JSON.parse(text);
		} catch {
			body = undefined;
		}
		return yield* decodeResponse(request.route, response.status, body, schema);
	});
}
