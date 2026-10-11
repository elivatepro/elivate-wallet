// Blueprint 25: "Offices this month" on the network home (Paper NV01/NV03) for
// the selected workspace. The month is the network's own (its time zone), so
// the read takes no query.
import { Effect } from 'effect';
import { LedgerApi } from '#lib/server/apis-ledger.js';
import { workspaceCookie, workspaceGone } from '#lib/server/money.js';
import { invalidRequest, respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = workspaceCookie(event);
	if (!membershipId) return respondError(workspaceGone());
	const extra = [...event.url.searchParams.keys()][0];
	if (extra !== undefined) return respondError(invalidRequest(extra));
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* LedgerApi).overviewOffices(membershipId);
		})
	);
	return respond(exit);
};
