// Transaction detail (Blueprint 08, Paper M03 panel / M05): own, or a managed
// wallet's with `?wallet=<walletId>` (visible segments only).
import { Effect } from 'effect';
import { UUID_PATTERN } from '#lib/contract/common.js';
import { LedgerApi } from '#lib/server/apis-ledger.js';
import { workspaceCookie, workspaceGone } from '#lib/server/money.js';
import { invalidRequest, respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const id = event.params.id;
	if (!UUID_PATTERN.test(id)) return respondError(invalidRequest('id'));
	const params = event.url.searchParams;
	for (const key of params.keys()) if (key !== 'wallet') return respondError(invalidRequest(key));
	const wallet = params.get('wallet');
	if (wallet !== null && !UUID_PATTERN.test(wallet)) return respondError(invalidRequest('wallet'));
	const membershipId = workspaceCookie(event);
	if (wallet && !membershipId) return respondError(workspaceGone());

	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const ledger = yield* LedgerApi;
			return wallet
				? yield* ledger.managedTransaction(membershipId!, wallet, id)
				: yield* ledger.transaction(id);
		})
	);
	return respond(exit);
};
