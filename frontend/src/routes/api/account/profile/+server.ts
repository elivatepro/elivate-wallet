// Edit own profile (W-22, Blueprint 06 `PATCH /identity/profile`): display
// name, phone (refused by the backend when the NIN supplied it) and rank.
// Legal name and UID cannot change here.
import { Effect } from 'effect';
import { ProfileEditCommand } from '#lib/contract/account.js';
import { IdentityApi, type ProfileChanges } from '#lib/server/apis-identity.js';
import { relayAccountCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const PATCH: RequestHandler = (event) =>
	relayAccountCommand(event, ProfileEditCommand, ({ idempotencyKey, ...fields }) => {
		const changes: ProfileChanges = {
			...(fields.displayName !== undefined ? { displayName: fields.displayName } : {}),
			...(fields.phone !== undefined ? { phone: fields.phone } : {}),
			...(fields.rank !== undefined ? { rank: fields.rank } : {})
		};
		return Effect.gen(function* () {
			return yield* (yield* IdentityApi).updateProfile(changes, idempotencyKey);
		});
	});
