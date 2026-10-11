// The person picker's search (Blueprint 27): a name among the network's
// people, or an exact UID or full email address among all accounts.
import { FoundPeople, OrgAdminRoutes } from '#lib/contract/org-admin.js';
import { OrgAdminApi } from '#lib/server/apis-org.js';
import { orgRead } from '#lib/server/org-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import { Effect } from 'effect';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) => {
	const q = event.url.searchParams.get('q')?.trim() ?? '';
	if (q.length < 2 || q.length > 254 || [...event.url.searchParams.keys()].some((k) => k !== 'q')) {
		return Promise.resolve(respondError(invalidRequest('q')));
	}
	return orgRead(event, (membershipId) =>
		Effect.gen(function* () {
			return yield* (yield* OrgAdminApi).read(
				'org',
				OrgAdminRoutes.people,
				FoundPeople,
				membershipId,
				{
					q
				}
			);
		})
	);
};
