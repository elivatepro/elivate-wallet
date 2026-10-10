// Restore an older settings revision (W-20 rollback; Paper F02 "Restore"): a
// new revision with the old values, manage_team_settings + PIN.
import { Effect } from 'effect';
import { RestoreRevisionCommand } from '#lib/contract/settings.js';
import { SettingsApi } from '#lib/server/apis-settings.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayCommand(event, RestoreRevisionCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).restoreRevision(membershipId, {
				expectedRevision: body.expectedRevision,
				revision: body.revision,
				idempotencyKey: body.idempotencyKey
			});
		})
	);
