import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import {
	ADMIN_PATHS,
	adminGateState,
	adminPathForGate,
	adminRedirectFor
} from '#lib/server/admin.js';
import { failureOf } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { session, state } = await adminGateState(event);
	if (state.gate !== 'pin_required') redirect(303, adminPathForGate(state.gate));
	return { email: maskEmail(session.email) };
};

function maskEmail(email: string | null): string | null {
	if (!email || email.indexOf('@') < 1) return null;
	return `${email[0]}•••••${email.slice(email.indexOf('@'))}`;
}

export const actions: Actions = {
	default: async (event) => {
		const { session, state } = await adminGateState(event);
		if (state.gate !== 'pin_required') redirect(303, adminPathForGate(state.gate));
		const pin = String((await event.request.formData()).get('pin') ?? '');
		// Never retried automatically: each attempt counts.
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).verifyPin({ pin });
			})
		);
		if (Exit.isSuccess(exit)) redirect(303, ADMIN_PATHS.home);
		const failure = failureOf(exit);
		if (failure._tag === 'BackendError') {
			if (failure.code === 'validation_error')
				return fail(400, { error: 'Enter your 4-digit PIN.' });
			if (failure.code === 'pin_incorrect') {
				const left = Number(failure.details.attemptsRemaining);
				const tries = Number.isInteger(left)
					? ` ${left} ${left === 1 ? 'try' : 'tries'} left.`
					: '';
				return fail(403, { error: `That PIN is incorrect.${tries}` });
			}
		}
		adminRedirectFor(failure);
	}
};
