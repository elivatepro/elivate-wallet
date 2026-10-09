// What the member can withdraw from and to (M06): NGN pockets with available
// balances and their payout accounts (usable or not, with the reason shown).
import { WithdrawalRoutes, WithdrawalSources } from '#lib/contract/withdrawals.js';
import { ledgerRead, relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, {}, ledgerRead(WithdrawalRoutes.sources, WithdrawalSources));
