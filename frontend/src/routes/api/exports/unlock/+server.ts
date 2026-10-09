// Download report · PIN (Paper S14d): verifying the PIN opens the 5-minute
// step-up proof the backend asks for before a leadership report download.
import { Effect } from 'effect';
import { UnlockCommand } from '#lib/contract/exports.js';
import { SecurityApi } from '#lib/server/apis.js';
import { relayAccountCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayAccountCommand(event, UnlockCommand, ({ pin }) =>
		Effect.gen(function* () {
			yield* (yield* SecurityApi).verifyPin({ pin });
			return { unlocked: true };
		})
	);
