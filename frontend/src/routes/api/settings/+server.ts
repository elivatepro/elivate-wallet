// Team settings (Blueprint 17, W-20; Paper F01/F02, TS02d): the editable record
// and its revisions (GET) and a save (PATCH, manage_team_settings + PIN). The
// PIN opens the step-up here and never reaches the org function.
import { Effect } from 'effect';
import { SaveSettingsCommand } from '#lib/contract/settings.js';
import { SettingsApi } from '#lib/server/apis-settings.js';
import { relayCommand } from '#lib/server/command.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, {}, (membershipId) =>
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).settings(membershipId);
		})
	);

export const PATCH: RequestHandler = (event) =>
	relayCommand(event, SaveSettingsCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).save(membershipId, {
				expectedRevision: body.expectedRevision,
				fields: body.fields,
				idempotencyKey: body.idempotencyKey
			});
		})
	);
