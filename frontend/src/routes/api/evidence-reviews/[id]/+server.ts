// One review case with the receipt facts the check read (C09 right panel).
import { ReviewCase, WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import { ledgerRead, relayRead, validId } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	validId(event.params.id)
		? relayRead(event, {}, ledgerRead(WithdrawalRoutes.review(event.params.id), ReviewCase))
		: Promise.resolve(respondError(invalidRequest('id')));
