// One file: its state while it is made (GET, polled by S08/S06) and Retry
// after a failure (POST, re-authorized by the backend).
import { Effect } from 'effect';
import { ExportsApi } from '#lib/server/apis-exports.js';
import { kickRunner } from '#lib/server/exports/endpoints.js';
import { validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!validId(event.params.id)) return respondError(invalidRequest('id'));
	const id = event.params.id;
	return respond(
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* ExportsApi).file(id);
			})
		)
	);
};

export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!validId(event.params.id)) return respondError(invalidRequest('id'));
	if (!event.request.headers.get('content-type')?.startsWith('application/json')) {
		return respondError(invalidRequest('body'));
	}
	const id = event.params.id;
	const response = respond(
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* ExportsApi).retry(id);
			})
		)
	);
	if (response.ok) kickRunner();
	return response;
};
