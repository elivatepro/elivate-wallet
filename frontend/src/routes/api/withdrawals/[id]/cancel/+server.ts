// Cancel my requested withdrawal (Paper v2 W03/W04): no PIN, optional reason;
// the hold is released and no money moves.
import { Effect } from 'effect';
import { CancelOwnCommand, Withdrawal, WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { relayCommand } from '#lib/server/command.js';
import { validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = event.params.id;
	if (!validId(id)) return Promise.resolve(respondError(invalidRequest('id')));
	return relayCommand(event, CancelOwnCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* MoneyMovesApi).command(
				membershipId,
				WithdrawalRoutes.cancelOwn(id),
				body,
				Withdrawal
			);
		})
	);
};
