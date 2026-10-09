// Personal statements (Blueprint 15, W-18; Paper S08–S11): the builder's
// choices with the person's files (GET) and a new file (POST). Account-level:
// statements belong to the person, not the selected workspace.
import { Effect } from 'effect';
import { StatementCommand } from '#lib/contract/exports.js';
import { ExportsApi } from '#lib/server/apis-exports.js';
import { relayAccountCommand } from '#lib/server/command.js';
import { kickRunner } from '#lib/server/exports/endpoints.js';
import { CURSOR } from '#lib/server/money-endpoints.js';
import { invalidRequest, respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	for (const key of event.url.searchParams.keys()) {
		if (key !== 'cursor') return respondError(invalidRequest(key));
	}
	const cursor = event.url.searchParams.get('cursor');
	if (cursor !== null && !CURSOR.test(cursor)) return respondError(invalidRequest('cursor'));
	return respond(
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				const api = yield* ExportsApi;
				const [options, files] = yield* Effect.all([api.options, api.statements(cursor)], {
					concurrency: 2
				});
				return { options, files };
			})
		)
	);
};

export const POST: RequestHandler = async (event) => {
	const response = await relayAccountCommand(event, StatementCommand, (body) =>
		Effect.gen(function* () {
			return yield* (yield* ExportsApi).createStatement(body);
		})
	);
	if (response.ok) kickRunner();
	return response;
};
