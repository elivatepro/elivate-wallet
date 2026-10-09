// My withdrawals (W-09, Paper v2 W01/W02) and Request a withdrawal (v1 M06–M08).
// The request needs a fresh PIN: the confirm dialog's PIN opens the step-up,
// then the command is relayed with the browser's idempotency key. Never retried.
import { Effect } from 'effect';
import {
	RequestWithdrawalCommand,
	WithdrawalPage,
	Withdrawal,
	WithdrawalRoutes
} from '#lib/contract/withdrawals.js';
import { MoneyMovesApi } from '#lib/server/apis-withdrawals.js';
import { relayCommand } from '#lib/server/command.js';
import { CURSOR, ledgerRead, relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(
		event,
		{ status: /^(open|completed|closed)$/, cursor: CURSOR },
		ledgerRead(WithdrawalRoutes.mine, WithdrawalPage)
	);

export const POST: RequestHandler = (event) =>
	relayCommand(event, RequestWithdrawalCommand, (membershipId, body) =>
		Effect.gen(function* () {
			const { pin, ...input } = body;
			void pin;
			return yield* (yield* MoneyMovesApi).command(
				membershipId,
				WithdrawalRoutes.request,
				input,
				Withdrawal
			);
		})
	);
