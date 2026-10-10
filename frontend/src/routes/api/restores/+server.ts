// Request a restore (W-24; Paper V01/V02): President Team and World Team, with
// a reason. Only Elivate reviews and restores (owner answer Q1).
import { Effect } from 'effect';
import { RestoreRequestCommand } from '#lib/contract/settings.js';
import { SettingsApi } from '#lib/server/apis-settings.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayCommand(event, RestoreRequestCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).requestRestore(membershipId, body);
		})
	);
