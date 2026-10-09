// Turns the Paystack auto-renewal on or off (Blueprint 16 Q6, Paper PL09d).
import { Effect } from 'effect';
import { AutoRenewCommand } from '#lib/contract/billing.js';
import { BillingApi } from '#lib/server/apis-billing.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayCommand(event, AutoRenewCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* BillingApi).autoRenew(membershipId, body);
		})
	);
