// Browser side of the hybrid model (decision 36): the signed-in shell reads
// only from same-origin JSON endpoints and validates every response with the
// same Effect Schemas the server uses. No token ever reaches this code.

import { Effect, Schedule } from 'effect';
import { AppRoutes, SessionView } from '#lib/contract/app.js';
import { isRetryableRead, type ApiFailure } from '#lib/contract/errors.js';
import { READ_TIMEOUT_MS, requestJson } from '#lib/contract/transport.js';

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
			while: (e: ApiFailure) => isRetryableRead(e) && !(e._tag === 'TransportError' && e.reason === 'network'),
			schedule: Schedule.exponential('300 millis').pipe(Schedule.jittered)
		})
	);
}
