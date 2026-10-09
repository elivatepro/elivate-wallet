// Approver commands on one withdrawal (W-10). `[id]` is the withdrawal for
// approve / reject / cancel / reveal / payout, and the payout for correct /
// retry. A PIN from the dialog opens the step-up first (reveal, cancel after
// approval, record, correct, retry need one); then the command is relayed
// with the browser's idempotency key. Never retried here.
import { Effect, type Schema } from 'effect';
import {
	CorrectPayoutCommand,
	KeyCommand,
	PayoutCommand,
	ReasonCommand,
	RevealCommand,
	RevealedDestination,
	Withdrawal,
	WithdrawalRoutes
} from '#lib/contract/withdrawals.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { relayCommand } from '#lib/server/command.js';
import type { EdgeRoute } from '#lib/server/edge.js';
import { validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

/** Relays one command; the dialog PIN is used for the step-up only. */
const relay = <I extends Schema.ConstraintDecoder<object>>(
	event: Parameters<RequestHandler>[0],
	input: I,
	route: EdgeRoute,
	output: Schema.ConstraintDecoder<unknown>
) =>
	relayCommand(event, input, (membershipId, body) =>
		Effect.gen(function* () {
			const { pin, ...rest } = body as { pin?: string };
			void pin;
			return yield* (yield* MoneyMovesApi).command(membershipId, route, rest, output);
		})
	);

export const POST: RequestHandler = (event) => {
	const id = event.params.id;
	if (!validId(id)) return Promise.resolve(respondError(invalidRequest('id')));
	switch (event.params.action) {
		case 'approve':
			return relay(event, KeyCommand, WithdrawalRoutes.act(id, 'approve'), Withdrawal);
		case 'reject':
			return relay(event, ReasonCommand, WithdrawalRoutes.act(id, 'reject'), Withdrawal);
		case 'cancel':
			return relay(event, ReasonCommand, WithdrawalRoutes.act(id, 'cancel'), Withdrawal);
		case 'reveal':
			return relay(event, RevealCommand, WithdrawalRoutes.act(id, 'reveal'), RevealedDestination);
		case 'payout':
			return relay(event, PayoutCommand, WithdrawalRoutes.record(id), Withdrawal);
		case 'correct':
			return relay(event, CorrectPayoutCommand, WithdrawalRoutes.correct(id), Withdrawal);
		case 'retry':
			return relay(event, KeyCommand, WithdrawalRoutes.retry(id), Withdrawal);
		default:
			return Promise.resolve(respondError(invalidRequest('action')));
	}
};
