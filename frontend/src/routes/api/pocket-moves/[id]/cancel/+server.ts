// Cancel my requested pocket move; the hold is released.
import { Effect } from 'effect';
import { PocketTransfer, TransferKeyCommand, WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { relayCommand } from '#lib/server/command.js';
import { validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = event.params.id;
	if (!validId(id)) return Promise.resolve(respondError(invalidRequest('id')));
	return relayCommand(event, TransferKeyCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* MoneyMovesApi).command(
				membershipId,
				WithdrawalRoutes.cancelTransfer(id),
				body,
				PocketTransfer
			);
		})
	);
};
