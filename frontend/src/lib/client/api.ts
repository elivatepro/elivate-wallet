// Browser side of the hybrid model (decision 36): the signed-in shell reads
// only from same-origin JSON endpoints and validates every response with the
// same Effect Schemas the server uses. No token ever reaches this code.

import { Effect, Schedule, type Schema } from 'effect';
import { AppRoutes, HomeView, SessionView } from '#lib/contract/app.js';
import { isRetryableRead, type ApiFailure } from '#lib/contract/errors.js';
import { COMMAND_TIMEOUT_MS, READ_TIMEOUT_MS, requestJson } from '#lib/contract/transport.js';
import { invalidatesForPath } from './invalidation';
import { invalidate } from './page-cache.svelte';

export function loadSession(
	fetcher: typeof fetch,
	signal?: AbortSignal
): Effect.Effect<SessionView, ApiFailure> {
	return requestJson(
		{
			fetch: fetcher,
			url: AppRoutes.session.path,
			method: AppRoutes.session.method,
			route: `${AppRoutes.session.method} ${AppRoutes.session.path}`,
			timeoutMs: READ_TIMEOUT_MS,
			signal
		},
		SessionView
	).pipe(
		Effect.retry({
			times: 2,
			while: (e: ApiFailure) =>
				isRetryableRead(e) && !(e._tag === 'TransportError' && e.reason === 'network'),
			schedule: Schedule.exponential('300 millis').pipe(Schedule.jittered)
		})
	);
}

export function loadHome(
	fetcher: typeof fetch,
	signal?: AbortSignal
): Effect.Effect<HomeView, ApiFailure> {
	return requestJson(
		{
			fetch: fetcher,
			url: AppRoutes.home.path,
			method: AppRoutes.home.method,
			route: `${AppRoutes.home.method} ${AppRoutes.home.path}`,
			timeoutMs: READ_TIMEOUT_MS,
			signal
		},
		HomeView
	).pipe(
		Effect.retry({
			times: 2,
			while: (e: ApiFailure) =>
				isRetryableRead(e) && !(e._tag === 'TransportError' && e.reason === 'network'),
			schedule: Schedule.exponential('300 millis').pipe(Schedule.jittered)
		})
	);
}

const readRetry = {
	times: 2,
	while: (e: ApiFailure) =>
		isRetryableRead(e) && !(e._tag === 'TransportError' && e.reason === 'network'),
	schedule: Schedule.exponential('300 millis').pipe(Schedule.jittered)
};

/** A same-origin read, validated with its schema. */
export function getJson<S extends Schema.ConstraintDecoder<unknown>>(
	path: string,
	schema: S,
	signal?: AbortSignal
): Effect.Effect<S['Type'], ApiFailure> {
	return requestJson(
		{ fetch, url: path, method: 'GET', route: `GET ${path}`, timeoutMs: READ_TIMEOUT_MS, signal },
		schema
	).pipe(Effect.retry(readRetry));
}

/**
 * A same-origin command. Carries the workspace it was rendered for
 * (X-EW-Workspace, plan §5.8) and is never retried: on an unknown outcome
 * the caller resubmits with the same idempotency key. On success the cached
 * reads its path affects are forgotten and refetched (Blueprint 20 B6).
 */
export function sendCommand<S extends Schema.ConstraintDecoder<unknown>>(
	path: string,
	method: 'POST' | 'PUT' | 'PATCH',
	body: unknown,
	workspaceId: string,
	schema: S
): Effect.Effect<S['Type'], ApiFailure> {
	return sendCommandOnly(path, method, body, workspaceId, schema).pipe(
		Effect.tap(() => Effect.sync(() => invalidate(invalidatesForPath(path))))
	);
}

/** sendCommand without the cache step: CommandAttempt invalidates per command. */
export function sendCommandOnly<S extends Schema.ConstraintDecoder<unknown>>(
	path: string,
	method: 'POST' | 'PUT' | 'PATCH',
	body: unknown,
	workspaceId: string,
	schema: S
): Effect.Effect<S['Type'], ApiFailure> {
	return requestJson(
		{
			fetch,
			url: path,
			method,
			route: `${method} ${path}`,
			headers: { 'x-ew-workspace': workspaceId },
			body,
			timeoutMs: COMMAND_TIMEOUT_MS
		},
		schema
	);
}

export const newKey = () => crypto.randomUUID().replaceAll('-', '');

/**
 * An account-level same-origin command (Blueprint 10: sessions, PIN change,
 * profile). No workspace echo: these do not depend on the selected workspace.
 * Never retried.
 */
export function sendAccountCommand<S extends Schema.ConstraintDecoder<unknown>>(
	path: string,
	method: 'POST' | 'PATCH',
	body: unknown,
	schema: S
): Effect.Effect<S['Type'], ApiFailure> {
	return requestJson(
		{ fetch, url: path, method, route: `${method} ${path}`, body, timeoutMs: COMMAND_TIMEOUT_MS },
		schema
	).pipe(Effect.tap(() => Effect.sync(() => invalidate(invalidatesForPath(path)))));
}
