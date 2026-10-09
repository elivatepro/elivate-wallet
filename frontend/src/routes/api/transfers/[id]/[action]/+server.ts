// Approve (posts the move at once) or reject (reason) a member's pocket move. No PIN.
import { Effect } from 'effect';
import {
	PocketTransfer,
	TransferKeyCommand,
	TransferReasonCommand,
	WithdrawalRoutes
} from '#lib/contract/withdrawals.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { relayCommand } from '#lib/server/command.js';
import { validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = event.params.id;
	const action = event.params.action;
	if (!validId(id)) return Promise.resolve(respondError(invalidRequest('id')));
	if (action !== 'approve' && action !== 'reject') {
		return Promise.resolve(respondError(invalidRequest('action')));
	}
	const schema = action === 'approve' ? TransferKeyCommand : TransferReasonCommand;
	return relayCommand(event, schema, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* MoneyMovesApi).command(
				membershipId,
				WithdrawalRoutes.actTransfer(id, action),
				body,
				PocketTransfer
			);
		})
	);
};
