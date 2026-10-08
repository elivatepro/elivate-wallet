// Roles & access (Paper R01–R06): the network's role permissions (President
// Team), cross-access assignments (manage_access_rules) and evidence
// reviewers (President Team), each read only when the workspace may see it.
// POST creates a cross-access assignment (R03/R04: reason + PIN).
import { Effect, Option } from 'effect';
import {
	AccessAssignments,
	CreateAccessCommand,
	OfficeRows,
	OrgAdminRoutes,
	Reviewers,
	RolePermissions,
	type AccessView
} from '#lib/contract/org-admin.js';
import { OrgApi } from '#lib/server/apis.js';
import { OrgAdminApi } from '#lib/server/apis-org.js';
import { allPages, currentWorkspace, orgCommand, orgRead } from '#lib/server/org-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	orgRead(event, (membershipId) =>
		Effect.gen(function* () {
			const api = yield* OrgAdminApi;
			const [workspace, capabilities] = yield* Effect.all(
				[currentWorkspace(membershipId), (yield* OrgApi).capabilities(membershipId)],
				{ concurrency: 2 }
			);
			const isPresident = workspace?.role === 'president_team_member';
			const canManageAccess = capabilities.permissions.includes('manage_access_rules');
			const [roles, assignments, reviewers, offices] = yield* Effect.all(
				[
					isPresident
						? Effect.option(
								api.read('org', OrgAdminRoutes.rolePermissions, RolePermissions, membershipId)
							)
						: Effect.succeedNone,
					canManageAccess
						? Effect.option(
								allPages((cursor) =>
									api.read('org', OrgAdminRoutes.access, AccessAssignments, membershipId, {
										limit: '100',
										...(cursor ? { cursor } : {})
									})
								)
							)
						: Effect.succeedNone,
					isPresident
						? Effect.option(api.read('org', OrgAdminRoutes.reviewers, Reviewers, membershipId))
						: Effect.succeedNone,
					canManageAccess
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
						: Effect.succeedNone
				],
				{ concurrency: 4 }
			);
			return {
				rolePermissions: Option.getOrNull(roles),
				assignments: Option.match(assignments, {
					onNone: () => null,
					onSome: (all) => ({ items: all.items, nextCursor: null })
				}),
				reviewers: Option.getOrNull(reviewers),
				canEditRoles: capabilities.permissions.includes('manage_role_permissions'),
				canManageAccess,
				isPresident,
				offices: Option.match(offices, {
					onNone: () => [],
					onSome: (all) => all.items.map((o) => ({ id: o.id, name: o.name, type: o.type }))
				})
			} satisfies AccessView;
		})
	);

export const POST: RequestHandler = (event) =>
	orgCommand(event, CreateAccessCommand, () => OrgAdminRoutes.createAccess);
