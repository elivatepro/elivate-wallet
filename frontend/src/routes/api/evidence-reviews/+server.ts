// Evidence review queue (W-11, Paper v1 C09/C10): payouts whose receipt did
// not match twice. Only people with an active reviewer assignment; never a
// case they submitted or one about their own withdrawal.
import { ReviewPage, WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { CURSOR, ledgerRead, relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(
		event,
		{ tab: /^(assigned|cleared|rejected|all)$/, cursor: CURSOR },
		ledgerRead(WithdrawalRoutes.reviews, ReviewPage)
	);
