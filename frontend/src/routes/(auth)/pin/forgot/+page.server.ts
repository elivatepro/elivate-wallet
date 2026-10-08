import { fail } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { expectGate, failureOf, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	await expectGate(event, 'pin_required', 'pin_locked', 'ready');
	return {};
};

export const actions: Actions = {
	default: async (event) => {
		const { session } = await expectGate(event, 'pin_required', 'pin_locked', 'ready');
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				const api = yield* SecurityApi;
				return yield* api.requestPinReset;
			})
		);
		if (Exit.isSuccess(exit)) return { sent: true, expiresAt: exit.value.expiresAt };
		const failure = failureOf(exit);
		if (failure._tag === 'BackendError' && failure.code === 'rate_limited') {
			return fail(429, { message: 'A link was just sent. Try again in a minute.' });
		}
		if (failure._tag === 'BackendError' && failure.code === 'internal_error') {
			// Plan §6.4 #8: the reset may be recorded even though the email failed,
			// and a retry within 60 s is rate limited. Never auto-retry; say so.
			return fail(503, {
				message: 'We couldn’t confirm the email was sent. If it doesn’t arrive, try again in a minute.'
			});
		}
		redirectForFailure(failure);
	}
};
