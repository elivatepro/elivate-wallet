// Billing Owner (W-19; Paper v2 B01/B02): candidates (GET ?q=) and the change
// (POST, manage_subscription + PIN). The PIN opens the step-up here and never
// reaches the billing function.
import { Effect } from 'effect';
import { OwnerCommand } from '#lib/contract/billing.js';
import { BillingApi } from '#lib/server/apis-billing.js';
import { relayCommand } from '#lib/server/command.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) =>
	relayRead(event, { q: /^.{0,100}$/s }, (membershipId, query) =>
		Effect.gen(function* () {
			return yield* (yield* BillingApi).ownerCandidates(membershipId, query.q ?? '');
		})
	);

export const POST: RequestHandler = (event) =>
	relayCommand(event, OwnerCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* BillingApi).changeOwner(membershipId, {
				membershipId: body.membershipId,
				idempotencyKey: body.idempotencyKey
			});
		})
	);
