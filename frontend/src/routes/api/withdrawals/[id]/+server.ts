// One of my withdrawals ("Track this withdrawal").
import { Withdrawal, WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import { ledgerRead, relayRead, validId } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	validId(event.params.id)
		? relayRead(event, {}, ledgerRead(WithdrawalRoutes.mineOne(event.params.id), Withdrawal))
		: Promise.resolve(respondError(invalidRequest('id')));
