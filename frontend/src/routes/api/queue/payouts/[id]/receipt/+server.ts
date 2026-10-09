// View a payout receipt (approver, reviewer): the backend checks who may see
// it and signs a 60-second link; this server follows it and streams the
// bytes, so the browser never sees a storage URL or token.
import { WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { streamEvidence, validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) => {
	const payoutId = event.params.id;
	if (!validId(payoutId)) return Promise.resolve(respondError(invalidRequest('id')));
	const params = [...event.url.searchParams.keys()];
	const revision = event.url.searchParams.get('revision');
	if (params.some((k) => k !== 'revision') || (revision !== '1' && revision !== '2')) {
		return Promise.resolve(respondError(invalidRequest('revision')));
	}
	return streamEvidence(event, WithdrawalRoutes.receipt(payoutId), { revision });
};
