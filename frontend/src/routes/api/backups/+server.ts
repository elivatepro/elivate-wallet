// Team Backup Vault (Blueprint 17, W-24; Paper E09/E10, TS03d): backups and
// restore requests (GET) and "Back up now" (POST, manage_team_settings).
import { Effect } from 'effect';
import { StartBackupCommand } from '#lib/contract/settings.js';
import { SettingsApi } from '#lib/server/apis-settings.js';
import { kickBackups } from '#lib/server/backups/endpoints.js';
import { relayCommand } from '#lib/server/command.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, {}, (membershipId) =>
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).vault(membershipId);
		})
	);

export const POST: RequestHandler = async (event) => {
	const response = await relayCommand(event, StartBackupCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).startBackup(membershipId, body);
		})
	);
	if (response.ok) kickBackups();
	return response;
};
