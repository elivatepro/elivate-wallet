// One office (Paper O07/O09): detail, subtree money, its own members; rename (O10/O11).
import { Effect } from 'effect';
import {
	MemberRows,
	OfficeDetail,
	OfficeRows,
	OfficeTotals,
	OrgAdminRoutes,
	RenameOfficeCommand,
	type OfficeView
} from '#lib/contract/org-admin.js';
import { OrgAdminApi } from '#lib/server/apis-org.js';
import {
	allPages,
	currentWorkspace,
	orgCommand,
	orgRead,
	pathId
} from '#lib/server/org-endpoints.js';
import { PARENT_TYPES } from '#lib/org.js';
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
			const isPresident = workspace?.role === 'president_team_member';
			// N04 choices: active offices of a strictly higher kind (never a descendant).
			const all =
				isPresident && office.status === 'active' && office.type !== 'world_team'
					? yield* Effect.option(
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
					: null;
			const offices = all && all._tag === 'Some' ? all.value.items : [];
			const names = new Map(offices.map((o) => [o.id, o.name]));
			return {
				office,
				totals: totals._tag === 'Some' ? totals.value : null,
				members: members._tag === 'Some' ? members.value : null,
				isPresident,
				parents: offices
					.filter((o) => PARENT_TYPES[office.type].includes(o.type) && o.id !== office.id)
					.map((o) => ({
						id: o.id,
						name: o.name,
						type: o.type,
						parentName: o.parentOfficeId ? (names.get(o.parentOfficeId) ?? null) : null
					}))
			} satisfies OfficeView;
		})
	);
};

export const PATCH: RequestHandler = (event) => {
	const id = pathId(event);
	if (typeof id !== 'string') return Promise.resolve(id);
	return orgCommand(event, RenameOfficeCommand, () => OrgAdminRoutes.renameOffice(id));
};
