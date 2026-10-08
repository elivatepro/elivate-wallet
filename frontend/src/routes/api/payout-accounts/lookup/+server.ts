// Account-name lookup (W-17): fresh step-up, exact bank code + 10-digit
// number. The number travels only in this POST body, never in a URL or log.
// Lookup is not confirmation; the person saves it explicitly.
import { Effect } from 'effect';
import { PayoutLookupCommand } from '#lib/contract/app.js';
import { PayoutApi } from '#lib/server/apis-identity.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayCommand(
		event,
		PayoutLookupCommand,
		(membershipId, { bankCode, accountNumber, idempotencyKey }) =>
			Effect.gen(function* () {
				return yield* (yield* PayoutApi).lookup(membershipId, {
					bankCode,
					accountNumber,
					idempotencyKey
				});
			})
	);
