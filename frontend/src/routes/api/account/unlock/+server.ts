// Unlock in place (Slice 28, Paper PU01–PU03): the PIN the session owes after
// it went idle, entered over the locked page. The PIN travels only in this POST
// body; it is never logged, cached or put in a URL. The backend counts the
// tries and locks the PIN after five, exactly as on /pin.
import { Effect } from 'effect';
import { UnlockCommand, type UnlockResult } from '#lib/contract/account.js';
import { SecurityApi } from '#lib/server/apis.js';
import { relayAccountCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayAccountCommand(event, UnlockCommand, (body) =>
		Effect.gen(function* () {
			const state = yield* (yield* SecurityApi).verifyPin(body);
			return { gate: state.gate } satisfies UnlockResult;
		})
	);
