// One payment (Paper v2 B05–B08, PL10d). Each read asks the backend, which
// checks an open payment with Paystack server-side; `returned=1` says the
// payer came back from Paystack's page.
import { Effect } from 'effect';
import { BillingApi } from '#lib/server/apis-billing.js';
import { relayRead, validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) => {
	const id = event.params.id;
	if (!validId(id)) return Promise.resolve(respondError(invalidRequest('id')));
	return relayRead(event, { returned: /^1$/ }, (membershipId, query) =>
		Effect.gen(function* () {
			return yield* (yield* BillingApi).payment(membershipId, id, query.returned === '1');
		})
	);
};
