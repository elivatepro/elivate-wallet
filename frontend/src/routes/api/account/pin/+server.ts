// Change the transaction PIN (Blueprint 10; Paper S05/S06). The PINs travel
// only in this POST body; they are never logged, cached or put in a URL.
import { Effect } from 'effect';
import { ChangePinCommand } from '#lib/contract/account.js';
import { SecurityApi } from '#lib/server/apis.js';
import { relayAccountCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayAccountCommand(event, ChangePinCommand, (body) =>
		Effect.gen(function* () {
			return yield* (yield* SecurityApi).changePin(body);
		})
	);
