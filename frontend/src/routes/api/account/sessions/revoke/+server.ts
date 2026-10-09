// Sign out one other device, or every other device (W-22, Blueprint 01 B4).
// PIN windows of the signed-out sessions close in the database (cascade).
import { Effect } from 'effect';
import { RevokeSessionsCommand } from '#lib/contract/account.js';
import { SecurityApi } from '#lib/server/apis.js';
import { relayAccountCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayAccountCommand(event, RevokeSessionsCommand, (body) =>
		Effect.gen(function* () {
			return yield* (yield* SecurityApi).revokeSessions(
				'sessionId' in body ? { sessionId: body.sessionId } : { allOthers: true }
			);
		})
	);
