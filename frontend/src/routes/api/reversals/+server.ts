// Reverse a posted transaction (W-15): reason, the reference typed back and
// the PIN; posts at once (Paper v4 MV05).
import { Effect } from 'effect';
import { EntryRoutes, Reversal, ReversalCommand } from '#lib/contract/entries.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayCommand(event, ReversalCommand, (membershipId, { pin: _pin, ...body }) =>
		Effect.gen(function* () {
			return yield* (yield* MoneyMovesApi).command(
				membershipId,
				EntryRoutes.reversals,
				body,
				Reversal
			);
		})
	);
