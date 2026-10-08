// Home data for the selected workspace (W-07): own wallet in this network,
// latest activity, split percentages. No cross-network or cross-currency sums.
import { Effect } from 'effect';
import type { HomeView } from '#lib/contract/app.js';
import { LedgerApi } from '#lib/server/apis-ledger.js';
import { OrgApi } from '#lib/server/apis.js';
import { readWorkspace } from '#lib/server/cookies.js';
import { respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import { BackendError } from '#lib/contract/errors.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) {
		return respondError(
			new BackendError({
				status: 403,
				code: 'workspace_invalid',
				message: 'Choose one of your active workspaces.',
				retryable: false,
				details: {},
				requestId: null
			})
		);
	}

	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const org = yield* OrgApi;
			const ledger = yield* LedgerApi;
			const workspace = (yield* org.workspaces).find((w) => w.membershipId === membershipId);
			if (!workspace) return yield* Effect.fail(workspaceGone());
			const empty: HomeView = { network: null, activity: [], split: null };

			const wallet = yield* ledger.wallet.pipe(
				Effect.catchIf(
					(e) => e._tag === 'BackendError' && e.code === 'no_wallet',
					() => Effect.succeed(null)
				)
			);
			const network = wallet?.networks.find((n) => n.tenantId === workspace.tenantId) ?? null;
			if (!network) return empty;

			const [activity, split] = yield* Effect.all(
				[
					ledger.activity({ tenantId: workspace.tenantId, limit: 5 }),
					// Percentages are a label; their absence never hides balances.
					ledger.allocation(membershipId).pipe(
						Effect.map((a) => a.pockets.map((p) => ({ pocketId: p.pocketId, percent: p.percent }))),
						Effect.orElseSucceed(() => null)
					)
				],
				{ concurrency: 2 }
			);
			return { network, activity: activity.items, split } satisfies HomeView;
		})
	);
	return respond(exit);
};

const workspaceGone = () =>
	new BackendError({
		status: 403,
		code: 'workspace_invalid',
		message: 'Choose one of your active workspaces.',
		retryable: false,
		details: {},
		requestId: null
	});
