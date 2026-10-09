// Save role-permission changes (Paper R01 save bar): one PIN, one reason, then
// each change as its own idempotent command, in order. A failure part-way
// leaves the earlier ones saved; resubmitting with the same keys replays them.
import { Effect } from 'effect';
import { OrgAdminRoutes, RoleChangesCommand } from '#lib/contract/org-admin.js';
import { OrgAdminApi } from '#lib/server/apis-org.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const PUT: RequestHandler = (event) =>
	relayCommand(event, RoleChangesCommand, (membershipId, body) =>
		Effect.gen(function* () {
			const api = yield* OrgAdminApi;
			const saved = yield* Effect.forEach(
				body.changes,
				(change) =>
					api.command(
						OrgAdminRoutes.setRolePermission,
						{ ...change, reason: body.reason },
						membershipId
					),
				{ concurrency: 1 }
			);
			return { saved: saved.length };
		})
	);
