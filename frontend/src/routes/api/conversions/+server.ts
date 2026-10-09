// Record a conversion (W-12, Paper v1 B07/B08): sent for review with its
// evidence; the converted amount is held until a reviewer decides. The
// optional dialog PIN opens the step-up first.
import { Effect } from 'effect';
import { ConversionCommand, Entry, EntryRoutes } from '#lib/contract/entries.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayCommand(event, ConversionCommand, (membershipId, { pin, ...body }) =>
		Effect.gen(function* () {
			void pin; // used for the step-up only (relayCommand)
			return yield* (yield* MoneyMovesApi).command(
				membershipId,
				EntryRoutes.conversions,
				body,
				Entry
			);
		})
	);
