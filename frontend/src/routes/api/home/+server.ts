// Home data for the selected workspace (W-07): own wallet in this network,
// latest activity, split percentages. No cross-network or cross-currency sums.
// Blueprint 20: one backend read (api.home_view); the backend resolves the
// network from the membership and checks it is the caller's.
import type { HomeView } from '#lib/contract/app.js';
import { LedgerApi } from '#lib/server/apis-ledger.js';
import { workspaceCookie, workspaceGone } from '#lib/server/money.js';
import { respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import { Effect } from 'effect';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = workspaceCookie(event);
	if (!membershipId) return respondError(workspaceGone());

	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return (yield* (yield* LedgerApi).home(membershipId)) satisfies HomeView;
		})
	);
	return respond(exit);
};
