// Submit an adjustment (W-14, Paper v1 E05/E06, v4 MV02): reason, evidence
// and the PIN always; posts once a reviewer clears it.
import { Effect } from 'effect';
import { AdjustmentCommand, Entry, EntryRoutes } from '#lib/contract/entries.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayCommand(event, AdjustmentCommand, (membershipId, { pin: _pin, ...body }) =>
		Effect.gen(function* () {
			return yield* (yield* MoneyMovesApi).command(
				membershipId,
				EntryRoutes.adjustments,
				body,
				Entry
			);
		})
	);
