import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { adminGateState, adminPathForGate } from '#lib/server/admin.js';
import { runApi } from '#lib/server/request.js';
import type { Actions, PageServerLoad } from './$types';

function maskEmail(email: string | null): string | null {
	if (!email || email.indexOf('@') < 1) return null;
	return `${email[0]}•••••${email.slice(email.indexOf('@'))}`;
}

export const load: PageServerLoad = async (event) => {
	const { session, state } = await adminGateState(event);
	if (state.gate !== 'pin_locked') redirect(303, adminPathForGate(state.gate));
	return { email: maskEmail(session.email) };
};

export const actions: Actions = {
	// The same single-use email reset as the Wallet app (A-05); 60-second cooldown.
	default: async (event) => {
		const { session, state } = await adminGateState(event);
		if (state.gate !== 'pin_locked') redirect(303, adminPathForGate(state.gate));
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).requestPinReset;
			})
		);
		if (Exit.isFailure(exit)) return fail(429, { error: 'Wait a minute, then try again.' });
		return { sent: true };
	}
};
