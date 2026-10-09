// Offices (Paper O01/O03, O04/O06): every office visible from the workspace
// with its subtree money per currency (W-05), and "New office" (President Team).
import { Effect, Option } from 'effect';
import {
	CreateOfficeCommand,
	OfficeRows,
	OfficeTotals,
	OrgAdminRoutes,
	type OfficeRow,
	type OfficesView
} from '#lib/contract/org-admin.js';
import { OrgApi } from '#lib/server/apis.js';
import { OrgAdminApi } from '#lib/server/apis-org.js';
import { currentWorkspace, orgCommand, orgRead } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

/** Pages fetched (100 offices each) and offices given a totals read. */
const MAX_PAGES = 5;
const MAX_TOTALS = 60;
const MONEY_PERMISSIONS = ['view_managed_wallets', 'view_scoped_financial_reports'];

export const GET: RequestHandler = (event) =>
	orgRead(event, (membershipId) =>
		Effect.gen(function* () {
			const api = yield* OrgAdminApi;
			const offices: OfficeRow[] = [];
			let cursor: string | null = null;
			let pages = 0;
			do {
				const query: Record<string, string> = { limit: '100' };
				if (cursor) query.cursor = cursor;
				const page = yield* api.read(
					'org',
					OrgAdminRoutes.offices,
					OfficeRows,
					membershipId,
					query
				);
				offices.push(...page.items);
				cursor = page.nextCursor;
				pages += 1;
			} while (cursor && pages < MAX_PAGES);

			const [workspace, capabilities] = yield* Effect.all(
				[currentWorkspace(membershipId), (yield* OrgApi).capabilities(membershipId)],
				{ concurrency: 2 }
			);
			const seesMoney = capabilities.permissions.some((p) => MONEY_PERMISSIONS.includes(p));
			const totals: Record<string, typeof OfficeTotals.Type> = {};
			if (seesMoney) {
				const active = offices.filter((o) => o.status === 'active').slice(0, MAX_TOTALS);
				const results = yield* Effect.forEach(
					active,
					(office) =>
						Effect.option(
							api.read('ledger', OrgAdminRoutes.officeTotals(office.id), OfficeTotals, membershipId)
						),
					{ concurrency: 6 }
				);
				results.forEach((result, i) => {
					const office = active[i];
					if (office && Option.isSome(result)) totals[office.id] = result.value;
				});
			}
			return {
				offices,
				totals,
				canCreate: workspace?.role === 'president_team_member',
				truncated: cursor !== null
			} satisfies OfficesView;
		})
	);

export const POST: RequestHandler = (event) =>
	orgCommand(event, CreateOfficeCommand, () => OrgAdminRoutes.createOffice);
