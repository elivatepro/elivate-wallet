// Managed wallets (Blueprint 04/08, W-07): members whose money the leader may
// view in the selected workspace, per currency, never their own.
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
	const query: { q?: string; cursor?: string } = {};
	for (const [key, value] of event.url.searchParams) {
		if (key === 'q' && value.trim() && value.length <= 100) query.q = value;
		else if (key === 'cursor' && value && value.length <= 500) query.cursor = value;
		else return respondError(invalidRequest(key));
	}
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* LedgerApi).managedWallets(membershipId, query);
		})
	);
	return respond(exit);
};
