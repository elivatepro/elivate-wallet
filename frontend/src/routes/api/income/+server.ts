// Record income (W-08; Blueprint 09): relays one command with the browser's
// idempotency key. The optional confirm-sheet PIN opens the step-up first.
// Never retried here; on an unknown outcome the browser re-sends the same key.
import { Effect } from 'effect';
import { RecordIncomeCommand } from '#lib/contract/income.js';
import { IncomeApi } from '#lib/server/apis-income.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayCommand(event, RecordIncomeCommand, (membershipId, body) =>
		Effect.gen(function* () {
			// The PIN was used for the step-up only; it never reaches the ledger route.
			const { pin, ...input } = body;
			void pin;
			return yield* (yield* IncomeApi).record(membershipId, input);
		})
	);
