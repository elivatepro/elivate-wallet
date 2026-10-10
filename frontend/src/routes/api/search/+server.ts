// Quick search (Blueprint 17, P-06; Paper K01/K02): people, offices and
// references the selected workspace can already see. The backend decides.
import { Effect } from 'effect';
import { SettingsApi } from '#lib/server/apis-settings.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, { q: /^\s*\S.{0,78}\S\s*$/s }, (membershipId, query) =>
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).search(membershipId, query.q ?? '');
		})
	);
