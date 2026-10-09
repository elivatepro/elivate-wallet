// Paystack hand-off for a network awaiting its first payment (Blueprint 16;
// Paper PL03). The checkout is opened server-side; its key lives in a
// short-lived HttpOnly cookie, so reloading this page reopens the same
// checkout instead of making another, and a definitely closed one (failed,
// abandoned, superseded) starts a fresh attempt. Paystack brings the payer
// back to /app/billing/payments/[id], where the server checks the payment.

import { redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { BillingApi } from '#lib/server/apis-billing.js';
import { readWorkspace } from '#lib/server/cookies.js';
import { expectGate, failureOf, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import { describeFailure } from '#lib/server/setup.js';
import { newIdempotencyKey } from '#lib/server/workspace.js';
import { IDEMPOTENCY_KEY_PATTERN } from '#lib/contract/common.js';
import type { PageServerLoad } from './$types';

const KEY_COOKIE = 'ew_setup_checkout';
const CLOSED = ['failed', 'abandoned', 'superseded'];

export const load: PageServerLoad = async (event) => {
	const { session } = await expectGate(event, 'ready');
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) redirect(303, '/setup');
	// The cookie holds "<membership>:<key>": a key is never replayed for another
	// network (the request names the membership).
	const [rememberedFor, remembered] = (event.cookies.get(KEY_COOKIE) ?? '').split(':');
	const firstKey =
		rememberedFor === membershipId && remembered && IDEMPOTENCY_KEY_PATTERN.test(remembered)
			? remembered
			: newIdempotencyKey();
	let usedKey = firstKey;
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* BillingApi;
			const view = yield* api.overview(membershipId);
			if (view.status !== 'pending') return { view, checkout: null };
			const open = (idempotencyKey: string) =>
				api.checkout(membershipId, { planKey: view.plan.key, kind: 'year', idempotencyKey });
			let checkout = yield* open(firstKey);
			if (checkout.status && CLOSED.includes(checkout.status)) {
				usedKey = newIdempotencyKey();
				checkout = yield* open(usedKey);
			}
			return { view, checkout };
		})
	);
	event.cookies.set(KEY_COOKIE, `${membershipId}:${usedKey}`, {
		path: '/setup',
		httpOnly: true,
		sameSite: 'lax',
		secure: event.locals.secureCookies,
		maxAge: 60 * 60 * 24
	});
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
