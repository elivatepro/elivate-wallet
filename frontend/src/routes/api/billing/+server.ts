// Billing & plan (Blueprint 16, W-19; Paper PL04/PL07d/PL08d): the selected
// network's subscription, seats, owner, plans and payments. Visible to
// manage_subscription holders and the Billing Owner; the backend decides.
import { Effect } from 'effect';
import { BillingApi } from '#lib/server/apis-billing.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, {}, (membershipId) =>
		Effect.gen(function* () {
			return yield* (yield* BillingApi).overview(membershipId);
		})
	);
