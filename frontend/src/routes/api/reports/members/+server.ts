// "One member" picker for Export report (Paper S05/S06): people whose money
// the leader may export in this workspace (export_scoped_reports).
import { Effect } from 'effect';
import { ExportsApi } from '#lib/server/apis-exports.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, { q: /^.{2,100}$/s }, (membershipId, query) =>
		Effect.gen(function* () {
			return yield* (yield* ExportsApi).members(membershipId, query.q ?? '');
		})
	);
