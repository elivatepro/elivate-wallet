// Opens a Paystack checkout (Blueprint 16): the backend prices it; the browser
// only receives the Paystack page to go to and Elivate's PAY reference.
import { Effect } from 'effect';
import { CheckoutCommand } from '#lib/contract/billing.js';
import { BillingApi } from '#lib/server/apis-billing.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayCommand(event, CheckoutCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* BillingApi).checkout(membershipId, body);
		})
	);
