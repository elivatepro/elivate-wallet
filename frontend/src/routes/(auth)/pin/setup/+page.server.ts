import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { expectGate, failureOf, redirectForFailure } from '#lib/server/flow.js';
import { readOnboardingMembership } from '#lib/server/onboarding.js';
import { runApi } from '#lib/server/request.js';
import { GATE_PATHS } from '#lib/gate.js';
import { pinFieldErrors } from '../pin-errors';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	await expectGate(event, 'pin_setup_required');
	// An accepted invitation sets its PIN inside the first-use wizard.
	if (readOnboardingMembership(event.cookies)) redirect(303, '/onboarding/pin');
	return {};
};

export const actions: Actions = {
	default: async (event) => {
		const { session } = await expectGate(event, 'pin_setup_required');
		const form = await event.request.formData();
		const input = {
			pin: String(form.get('pin') ?? ''),
			pinConfirm: String(form.get('pinConfirm') ?? '')
		};
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				const api = yield* SecurityApi;
				return yield* api.setPin(input);
			})
		);
		if (Exit.isSuccess(exit)) {
			// A founder who just accepted their invitation continues to network
			// setup (Blueprint 19); the only `next` this page honours.
			const founder = event.url.searchParams.get('next') === '/setup';
			redirect(303, founder && exit.value.gate === 'ready' ? '/setup' : GATE_PATHS[exit.value.gate]);
		}
		const failure = failureOf(exit);
		const errors = pinFieldErrors(failure);
		if (errors) return fail(400, { errors });
		if (failure._tag === 'BackendError' && failure.code === 'conflict') {
			// pin_already_set: another tab finished first; follow the gate.
			redirect(303, '/workspaces');
		}
		redirectForFailure(failure);
	}
};
