// Returned funds for one completed withdrawal (W-16, Paper v2 W07–W10): what
// can still come back, and recording a return with proof. `[id]` is the
// withdrawal.
import { Effect } from 'effect';
import { EntryRoutes, Returnable, ReturnCommand, ReturnedEntry } from '#lib/contract/entries.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { relayCommand } from '#lib/server/command.js';
import { ledgerRead, relayRead, validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	validId(event.params.id)
		? relayRead(event, {}, ledgerRead(EntryRoutes.returnable(event.params.id), Returnable))
		: Promise.resolve(respondError(invalidRequest('id')));

export const POST: RequestHandler = (event) => {
	const id = event.params.id;
	if (!validId(id)) return Promise.resolve(respondError(invalidRequest('id')));
	return relayCommand(event, ReturnCommand, (membershipId, { pin, ...body }) =>
		Effect.gen(function* () {
			void pin; // used for the step-up only (relayCommand)
			return yield* (yield* MoneyMovesApi).command(
				membershipId,
				EntryRoutes.returns(id),
				body,
				ReturnedEntry
			);
		})
	);
};
