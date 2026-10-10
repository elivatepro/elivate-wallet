// The selected network's brand (Blueprint 17, W-20): safe presentation fields
// for every member, including on a paused network.
import { Effect } from 'effect';
import { SettingsApi } from '#lib/server/apis-settings.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, {}, (membershipId) =>
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).brand(membershipId);
		})
	);
