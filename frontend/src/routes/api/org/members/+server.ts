// Members (Paper C11/C12): one page of the workspace's members, searchable by
// name or UID, filtered by status.
import { Effect, Schema } from 'effect';
import { MemberRows, OrgAdminRoutes } from '#lib/contract/org-admin.js';
import { UUID_PATTERN } from '#lib/contract/common.js';
import { OrgAdminApi } from '#lib/server/apis-org.js';
import { orgRead } from '#lib/server/org-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

const Query = Schema.Struct({
	q: Schema.optionalKey(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100))),
	status: Schema.optionalKey(Schema.Literals(['active', 'suspended', 'ended'])),
	role: Schema.optionalKey(
		Schema.Literals(['member', 'team_leader', 'director', 'world_team_member', 'president_team_member'])
	),
	officeId: Schema.optionalKey(Schema.String.check(Schema.isPattern(UUID_PATTERN))),
	cursor: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(500)))
});

export const GET: RequestHandler = (event) => {
	const raw: Record<string, string> = {};
	for (const field of ['q', 'status', 'role', 'officeId', 'cursor'] as const) {
		const value = event.url.searchParams.get(field);
		if (value !== null && value.trim() !== '') raw[field] = value.trim();
	}
	let query: typeof Query.Type;
	try {
		query = Schema.decodeUnknownSync(Query)(raw);
	} catch {
		return Promise.resolve(respondError(invalidRequest('query')));
	}
	return orgRead(event, (membershipId) =>
		Effect.gen(function* () {
			return yield* (yield* OrgAdminApi).read(
				'org',
				OrgAdminRoutes.members,
				MemberRows,
				membershipId,
				{
					...query,
					limit: '50'
				}
			);
		})
	);
};
