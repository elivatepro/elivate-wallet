// Remove (deactivate) an account (W-17; reason + PIN step-up). The record and
// any withdrawal snapshots stay; the backend refuses inactive accounts.
import { Effect, Schema } from 'effect';
import { PayoutRemoveCommand } from '#lib/contract/app.js';
import { Uuid } from '#lib/contract/common.js';
import { PayoutApi } from '#lib/server/apis-identity.js';
import { invalidRequest, relayCommand } from '#lib/server/command.js';
import { respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) => {
	const id = event.params.id;
	if (!Schema.is(Uuid)(id)) return respondError(invalidRequest('payoutAccountId'));
	return relayCommand(event, PayoutRemoveCommand, (membershipId, { reason, idempotencyKey }) =>
		Effect.gen(function* () {
			return yield* (yield* PayoutApi).deactivate(membershipId, id, { reason, idempotencyKey });
		})
	);
};
