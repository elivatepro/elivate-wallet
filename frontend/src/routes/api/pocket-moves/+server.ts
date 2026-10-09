// My pocket moves (W-13): list and request (Paper v1 B05/B06). No PIN; the
// amount is held until a leader approves (or I cancel).
import { Effect } from 'effect';
import {
	PocketTransfer,
	RequestTransferCommand,
	TransferPage,
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
		ledgerRead(WithdrawalRoutes.myTransfers, TransferPage)
	);

export const POST: RequestHandler = (event) =>
	relayCommand(event, RequestTransferCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* MoneyMovesApi).command(
				membershipId,
				WithdrawalRoutes.requestTransfer,
				body,
				PocketTransfer
			);
		})
	);
