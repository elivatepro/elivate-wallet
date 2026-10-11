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

/**
 * Slice 28: the browser shell watches every same-origin reply, so a PIN owed
 * anywhere (any page, any read or command) locks the app in place. Set only in
 * the browser; the app server never registers one.
 */
export interface ReplyObserver {
	/** A reply came back from the server (any status). */
	readonly replied: () => void;
	/** The server refused with this error code. */
	readonly refused: (code: string) => void;
}

let observer: ReplyObserver | null = null;

/** Registers the browser's observer; returns the unregister function. */
export function observeReplies(next: ReplyObserver): () => void {
	if (typeof window === 'undefined') return () => {};
	observer = next;
	return () => {
		if (observer === next) observer = null;
	};
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
					redirect: 'manual', // Workers reject 'error'; a 3xx is not ok and fails below
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
		observer?.replied();
		return yield* decodeResponse(request.route, response.status, parseJson(text), schema).pipe(
			Effect.tapError((failure) =>
				Effect.sync(() => {
					if (failure._tag === 'BackendError') observer?.refused(failure.code);
				})
			)
		);
	});
}

/** Parsed JSON, or undefined for an empty or non-JSON body (HTML 502 pages...). */
function parseJson(text: string): unknown {
	if (text === '') return undefined;
	try {
		return JSON.parse(text);
	} catch {
		return undefined;
	}
}
