// Withdrawal queue for approvers (W-10, Paper v1 T03/T06): Needs action,
// Verifying, Completed, Rejected & cancelled. The backend scopes it to the
// members this person may approve for and never lists their own.
import { WithdrawalPage, WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { CURSOR, ledgerRead, relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(
		event,
		{ tab: /^(action|verifying|completed|closed)$/, cursor: CURSOR },
		ledgerRead(WithdrawalRoutes.queue, WithdrawalPage)
	);
