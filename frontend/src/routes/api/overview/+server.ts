// Leadership dashboard (Blueprint 08 B4.3, Paper T01/T04) for the selected
// workspace. `tz` is the browser's zone for "this month" and the weeks.
import { Effect } from 'effect';
import { LedgerApi } from '#lib/server/apis-ledger.js';
import { parseActivityQuery, workspaceCookie, workspaceGone } from '#lib/server/money.js';
import { invalidRequest, respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = workspaceCookie(event);
	if (!membershipId) return respondError(workspaceGone());
	for (const key of event.url.searchParams.keys()) {
		if (key !== 'tz') return respondError(invalidRequest(key));
	}
	const parsed = parseActivityQuery(event.url.searchParams);
	if ('invalid' in parsed) return respondError(invalidRequest(parsed.invalid));
	const tz = parsed.query.tz ?? null;
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* LedgerApi).overview(membershipId, tz);
		})
	);
	return respond(exit);
};
