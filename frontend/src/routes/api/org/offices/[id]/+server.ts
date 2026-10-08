// One office (Paper O07/O09): detail, subtree money, its own members; rename (O10/O11).
import { Effect } from 'effect';
import {
	MemberRows,
	OfficeDetail,
	OfficeTotals,
	OrgAdminRoutes,
	RenameOfficeCommand,
	type OfficeView
} from '#lib/contract/org-admin.js';
import { OrgAdminApi } from '#lib/server/apis-org.js';
import { currentWorkspace, orgCommand, orgRead, pathId } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	return orgRead(event, (membershipId) =>
		Effect.gen(function* () {
			const api = yield* OrgAdminApi;
			const office = yield* api.read('org', OrgAdminRoutes.office(id), OfficeDetail, membershipId);
			const [totals, members, workspace] = yield* Effect.all(
				[
					// Unavailable or not permitted: the page shows the honest "—".
					office.status === 'active'
						? Effect.option(
								api.read('ledger', OrgAdminRoutes.officeTotals(id), OfficeTotals, membershipId)
							)
						: Effect.succeedNone,
					Effect.option(
						api.read('org', OrgAdminRoutes.members, MemberRows, membershipId, {
							officeId: id,
							limit: '50'
						})
					),
					currentWorkspace(membershipId)
				],
				{ concurrency: 3 }
			);
			return {
				office,
				totals: totals._tag === 'Some' ? totals.value : null,
				members: members._tag === 'Some' ? members.value : null,
				isPresident: workspace?.role === 'president_team_member'
			} satisfies OfficeView;
		})
	);
};

export const PATCH: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	return orgCommand(event, RenameOfficeCommand, () => OrgAdminRoutes.renameOffice(id));
};
