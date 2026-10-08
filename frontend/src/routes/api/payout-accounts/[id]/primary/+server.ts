// Make an account primary (W-17; PIN step-up). The backend decides eligibility.
import { Effect, Schema } from 'effect';
import { PayoutPrimaryCommand } from '#lib/contract/app.js';
import { Uuid } from '#lib/contract/common.js';
import { PayoutApi } from '#lib/server/apis-identity.js';
import { invalidRequest, relayCommand } from '#lib/server/command.js';
import { respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = event.params.id;
	if (!Schema.is(Uuid)(id)) return respondError(invalidRequest('payoutAccountId'));
	return relayCommand(event, PayoutPrimaryCommand, (membershipId, { idempotencyKey }) =>
		Effect.gen(function* () {
			return yield* (yield* PayoutApi).setPrimary(membershipId, id, { idempotencyKey });
		})
	);
};
