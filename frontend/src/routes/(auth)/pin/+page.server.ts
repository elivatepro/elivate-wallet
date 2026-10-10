import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { expectGate, failureOf, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import { GATE_PATHS, safeAppNext, safeNext, withNext } from '#lib/gate.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { state } = await expectGate(event, 'pin_required');
	return { attemptsRemaining: state.attemptsRemaining };
};

export const actions: Actions = {
	default: async (event) => {
		const { session } = await expectGate(event, 'pin_required');
		const form = await event.request.formData();
		const pin = String(form.get('pin') ?? '');
		// Never retried automatically: each attempt counts (Blueprint 01 B4).
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				const api = yield* SecurityApi;
				return yield* api.verifyPin({ pin });
			})
		);
		if (Exit.isSuccess(exit)) {
			if (exit.value.gate !== 'ready') redirect(303, GATE_PATHS[exit.value.gate]);
			const next = safeNext(event.url.searchParams.get('next'));
			// An app page goes back through the workspace picker, which opens it once a
			// workspace is set (slice 21); /join, /founder and /onboarding go straight back.
			redirect(303, safeAppNext(next) ? withNext('/workspaces', next) : (next ?? '/workspaces'));
		}
		const failure = failureOf(exit);
		if (failure._tag === 'BackendError') {
			if (failure.code === 'validation_error') {
				return fail(400, { error: 'Enter your 4-digit PIN.' });
			}
			if (failure.code === 'pin_incorrect') {
				const left = Number(failure.details.attemptsRemaining);
				const tries = Number.isInteger(left) ? `${left} ${left === 1 ? 'try' : 'tries'} left.` : '';
				return fail(403, { error: `That PIN is incorrect. ${tries}`.trim() });
			}
		}
		redirectForFailure(failure);
	}
};
