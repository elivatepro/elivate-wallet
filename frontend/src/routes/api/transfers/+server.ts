// Pocket moves waiting on a leader (W-13, Paper v2 W05/W06): Waiting on you, History.
import { TransferPage, WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { CURSOR, ledgerRead, relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(
		event,
		{ tab: /^(waiting|history)$/, cursor: CURSOR },
		ledgerRead(WithdrawalRoutes.transferQueue, TransferPage)
	);
