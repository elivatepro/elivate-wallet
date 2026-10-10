// Operations Elivate has stopped for the selected network (Blueprint 18, W-23):
// write pages show the paused state ahead of time. The database still refuses
// every stopped operation (`conflict` + operation_paused).
import { Effect } from 'effect';
import { OrgApi } from '#lib/server/apis.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, {}, (membershipId) =>
		Effect.gen(function* () {
			return yield* (yield* OrgApi).stoppedOperations(membershipId);
		})
	);
