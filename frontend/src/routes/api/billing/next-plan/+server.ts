// Next year's band (Blueprint 16 Q6, Paper PL09d): a smaller band the current
// seats fit, or null to keep the current one.
import { Effect } from 'effect';
import { NextPlanCommand } from '#lib/contract/billing.js';
import { BillingApi } from '#lib/server/apis-billing.js';
import { relayCommand } from '#lib/server/command.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = (event) =>
	relayCommand(event, NextPlanCommand, (membershipId, body) =>
		Effect.gen(function* () {
			return yield* (yield* BillingApi).nextPlan(membershipId, body);
		})
	);
