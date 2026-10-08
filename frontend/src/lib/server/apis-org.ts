// OrgAdminApi (Blueprint 07): the org-management reads and commands of the
// `org` Edge Function plus the ledger's office/wallet totals. The app server's
// /api/org/* endpoints decode every request body with its contract schema
// before calling here; responses are decoded with the route schema. Reads
// retry at most twice on transient failures; commands never retry (the caller
// keeps its idempotency key, W-00).

import { Context, Effect, Layer, Schedule, type Schema } from 'effect';
import { isRetryableRead } from '#lib/contract/errors.js';
import { CommandResult } from '#lib/contract/org-admin.js';
import { EdgeTransport, type EdgeFailure, type EdgeRoute } from './edge';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

export interface OrgAdminApiShape {
	readonly read: <S extends Schema.ConstraintDecoder<unknown>>(
		fn: 'org' | 'ledger',
		route: EdgeRoute,
		schema: S,
		membershipId: string,
		query?: Readonly<Record<string, string>>
	) => Effect.Effect<S['Type'], EdgeFailure>;
	readonly command: (
		route: EdgeRoute,
		body: Readonly<Record<string, unknown>>,
		membershipId: string
	) => Effect.Effect<typeof CommandResult.Type, EdgeFailure>;
}

export class OrgAdminApi extends Context.Service<OrgAdminApi, OrgAdminApiShape>()('OrgAdminApi') {}

export const OrgAdminApiLive = Layer.effect(
	OrgAdminApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		return {
			read: (fn, route, schema, membershipId, query) =>
				edge
					.call({ fn, route, membershipId, ...(query ? { query } : {}) }, schema)
					.pipe(Effect.retry(readPolicy)),
			command: (route, body, membershipId) =>
				edge.call({ fn: 'org', route, body, membershipId }, CommandResult)
		};
	})
);
