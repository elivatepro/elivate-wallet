// Withdraw a restore request before restoring starts (W-24): the requester or a President.
import { Effect } from 'effect';
import { CancelRestoreCommand } from '#lib/contract/settings.js';
import { SettingsApi } from '#lib/server/apis-settings.js';
import { relayCommand } from '#lib/server/command.js';
import { validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = event.params.id;
	if (!validId(id)) return Promise.resolve(respondError(invalidRequest('id')));
	return relayCommand(event, CancelRestoreCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).cancelRestore(membershipId, id, body);
		})
	);
};
