// Paystack hand-off for a network awaiting its first payment (Blueprint 16;
// Paper PL03). The checkout is opened server-side with a key fixed per
// network, plan and WAT day, so reloading this page reopens the same checkout
// instead of making another. Paystack brings the payer back to
// /app/billing/payments/[id], where the server checks the payment itself.

import { redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { BillingApi } from '#lib/server/apis-billing.js';
import { readWorkspace } from '#lib/server/cookies.js';
import { expectGate, failureOf, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import { describeFailure } from '#lib/server/setup.js';
import type { PageServerLoad } from './$types';

const watDay = () =>
	new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Lagos' })
		.format(new Date())
		.replaceAll('-', '');

export const load: PageServerLoad = async (event) => {
	const { session } = await expectGate(event, 'ready');
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) redirect(303, '/setup');
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* BillingApi;
			const view = yield* api.overview(membershipId);
			if (view.status !== 'pending') return { view, checkout: null };
			const checkout = yield* api.checkout(membershipId, {
				planKey: view.plan.key,
				kind: 'year',
				idempotencyKey: `setup${membershipId.replaceAll('-', '')}${view.plan.key}${watDay()}`
			});
			return { view, checkout };
		})
	);
	if (Exit.isFailure(exit)) {
		const failure = failureOf(exit);
		const message = describeFailure(failure);
		if (!message) redirectForFailure(failure);
		return { network: null, plan: null, checkout: null, message };
	}
	const { view, checkout } = exit.value;
	if (!checkout) redirect(303, '/app/billing');
	if (checkout.status === 'paid' && checkout.paymentId) {
		redirect(303, `/app/billing/payments/${checkout.paymentId}`);
	}
	return { network: view.network, plan: view.plan, checkout, message: null };
};
