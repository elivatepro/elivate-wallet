// One membership (Paper R07/R08): detail, the member's wallet totals when the
// leader may see them, and the offices a move can target.
import { Effect } from 'effect';
import {
	ManagedWalletTotals,
	MemberDetail,
	OfficeRows,
	OrgAdminRoutes,
	type MemberView
} from '#lib/contract/org-admin.js';
import type { Currency } from '#lib/contract/ledger.js';
import { OrgAdminApi } from '#lib/server/apis-org.js';
import { allPages, currentWorkspace, orgRead, pathId } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	return orgRead(event, (membershipId) =>
		Effect.gen(function* () {
			const api = yield* OrgAdminApi;
			const member = yield* api.read('org', OrgAdminRoutes.member(id), MemberDetail, membershipId);
			const [wallet, offices, workspace] = yield* Effect.all(
				[
					member.walletId && !member.isSelf
						? Effect.option(
								api.read(
									'ledger',
									OrgAdminRoutes.wallet(member.walletId),
									ManagedWalletTotals,
									membershipId
								)
							)
						: Effect.succeedNone,
					member.actions.move
						? Effect.option(
								allPages(
									(cursor) =>
										api.read('org', OrgAdminRoutes.offices, OfficeRows, membershipId, {
											status: 'active',
											limit: '100',
											...(cursor ? { cursor } : {})
										}),
									5
								)
							)
						: Effect.succeedNone,
					currentWorkspace(membershipId)
				],
				{ concurrency: 3 }
			);
			// Only this network's segments; currencies never mixed (F-01).
			const balances =
				wallet._tag === 'Some' && workspace
					? (['NGN', 'USD'] as Currency[]).flatMap((currency) => {
							const row = wallet.value.networks
								.filter((n) => n.tenantId === workspace.tenantId)
								.flatMap((n) => n.currencies)
								.find((c) => c.currency === currency);
							return row ? [{ currency, posted: row.posted, available: row.available }] : [];
						})
					: null;
			return {
				member,
				balances,
				walletId: wallet._tag === 'Some' && workspace ? wallet.value.walletId : null,
				offices:
					offices._tag === 'Some'
						? offices.value.items.map((o) => ({ id: o.id, name: o.name, type: o.type }))
						: []
			} satisfies MemberView;
		})
	);
};
