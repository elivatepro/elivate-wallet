// The President's read-only network audit log (Paper F05/F06; D-11), newest first.
import { Effect, Schema } from 'effect';
import { AuditEvents, OrgAdminRoutes } from '#lib/contract/org-admin.js';
import { OrgAdminApi } from '#lib/server/apis-org.js';
import { orgRead } from '#lib/server/org-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

const Cursor = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(500));

export const GET: RequestHandler = (event) => {
	const cursor = event.url.searchParams.get('cursor');
	if (cursor !== null && !Schema.is(Cursor)(cursor)) {
		return Promise.resolve(respondError(invalidRequest('cursor')));
	}
	return orgRead(event, (membershipId) =>
		Effect.gen(function* () {
			return yield* (yield* OrgAdminApi).read(
				'org',
				OrgAdminRoutes.audit,
				AuditEvents,
				membershipId,
				{
					limit: '50',
					...(cursor ? { cursor } : {})
				}
			);
		})
	);
};
