// Which of my pockets can send and receive (B05), per office and currency.
import { TransferChoices, WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { ledgerRead, relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, {}, ledgerRead(WithdrawalRoutes.choices, TransferChoices));
