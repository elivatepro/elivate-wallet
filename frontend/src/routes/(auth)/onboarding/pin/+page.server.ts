// Wizard step 1 (Paper 02/03): the 4-digit PIN, entered twice. One form: the
// first PIN is never carried between requests.
import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { failureOf, redirectForFailure } from '#lib/server/flow.js';
import { expectStep, stepTotal } from '#lib/server/onboarding.js';
import { runApi } from '#lib/server/request.js';
import { pinFieldErrors } from '../../pin/pin-errors';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'pin');
	return { total: stepTotal(wizard.level) };
};

export const actions: Actions = {
	default: async (event) => {
		const { wizard } = await expectStep(event, 'pin');
		const form = await event.request.formData();
		const input = {
			pin: String(form.get('pin') ?? ''),
			pinConfirm: String(form.get('pinConfirm') ?? '')
		};
		const exit = await runApi(
			event,
			wizard.session,
			Effect.gen(function* () {
				return yield* (yield* SecurityApi).setPin(input);
			})
		);
		if (Exit.isSuccess(exit)) redirect(303, '/onboarding/continue');
		const failure = failureOf(exit);
		const errors = pinFieldErrors(failure);
		if (errors) return fail(400, { errors });
		if (failure._tag === 'BackendError' && failure.code === 'conflict') {
			redirect(303, '/onboarding/continue');
		}
		redirectForFailure(failure);
	}
};
