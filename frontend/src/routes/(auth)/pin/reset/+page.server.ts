import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { failureOf, redirectForFailure, requireSession } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import { GATE_PATHS } from '#lib/gate.js';
import { pinFieldErrors } from '../pin-errors';
import type { Actions, PageServerLoad } from './$types';

// Reached from the emailed reset link (magic-link session, plan §7.4). The
// database decides whether this session may complete the reset.
export const load: PageServerLoad = async (event) => {
	await requireSession(event);
	return {};
};

export const actions: Actions = {
	default: async (event) => {
		const session = await requireSession(event);
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
				return yield* api.completePinReset(input);
			})
		);
		if (Exit.isSuccess(exit)) redirect(303, GATE_PATHS[exit.value.gate]);
		const failure = failureOf(exit);
		const errors = pinFieldErrors(failure);
		if (errors) return fail(400, { errors });
		if (failure._tag === 'BackendError') {
			if (failure.code === 'conflict') {
				return fail(409, { message: 'This reset has expired. Request a new link.' });
			}
			if (failure.code === 'authorization_denied') redirect(303, '/pin/forgot');
		}
		redirectForFailure(failure);
	}
};
