// Activity (Blueprint 08, W-07; Paper M03/M04). Own activity in the selected
// network, or a managed wallet's (`?wallet=<walletId>`, view_managed_wallets
// per segment, checked by the backend). All currencies and dates until
// filtered; month summaries come from the backend's aggregate read.
// Blueprint 20: the backend resolves the network from the membership, so the
// workspace list is no longer fetched first.
import { Effect } from 'effect';
import type { ActivityView } from '#lib/contract/app.js';
import { UUID_PATTERN } from '#lib/contract/common.js';
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
	const wallet = event.url.searchParams.get('wallet');
	if (wallet !== null && !UUID_PATTERN.test(wallet)) return respondError(invalidRequest('wallet'));
	const parsed = parseActivityQuery(event.url.searchParams, ['wallet']);
	if ('invalid' in parsed) return respondError(invalidRequest(parsed.invalid));
	const query = parsed.query;
	const firstPage = !query.cursor;

	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const ledger = yield* LedgerApi;
			if (wallet) {
				const [activity, managed] = yield* Effect.all(
					[
						ledger.managedActivity(membershipId, wallet, query),
						firstPage ? ledger.managedWallet(membershipId, wallet) : Effect.succeed(null)
					],
					{ concurrency: 2 }
				);
				// The backend limits a managed wallet to the workspace's network.
				const network = managed?.networks[0];
				return {
					activity,
					pockets: managed ? (network?.pockets ?? []) : null,
					person: managed?.person ?? null
				} satisfies ActivityView;
			}
			const [activity, own] = yield* Effect.all(
				[
					ledger.activity(query, membershipId),
					firstPage ? ledger.walletIn(membershipId) : Effect.succeed(null)
				],
				{ concurrency: 2 }
			);
			// Both are limited to the workspace's network by the backend.
			const network = own?.networks[0];
			return {
				activity,
				pockets: own ? (network?.pockets ?? []) : null,
				person: null
			} satisfies ActivityView;
		})
	);
	return respond(exit);
};
