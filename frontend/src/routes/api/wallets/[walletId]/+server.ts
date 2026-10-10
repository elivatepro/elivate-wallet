// One member's wallet for a leader (Blueprint 08, Paper Q05): balances per
// network currency and pocket (visible segments only) and the latest three
// movements. The backend authorizes every segment (view_managed_wallets).
import { Effect } from 'effect';
import type { MemberWalletView } from '#lib/contract/app.js';
import { UUID_PATTERN } from '#lib/contract/common.js';
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
	const walletId = event.params.walletId;
	if (!UUID_PATTERN.test(walletId)) return respondError(invalidRequest('walletId'));
	const extra = [...event.url.searchParams.keys()][0];
	if (extra) return respondError(invalidRequest(extra));
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const ledger = yield* LedgerApi;
			const [wallet, recent] = yield* Effect.all(
				[
					ledger.managedWallet(membershipId, walletId),
					ledger.managedActivity(membershipId, walletId, { limit: 3 })
				],
				{ concurrency: 2 }
			);
			return {
				wallet,
				// Blueprint 20: the backend limits it to the workspace's network.
				network: wallet.networks[0] ?? null,
				recent: recent.items
			} satisfies MemberWalletView;
		})
	);
	return respond(exit);
};
