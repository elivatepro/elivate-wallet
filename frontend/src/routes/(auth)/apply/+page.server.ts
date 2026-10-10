// Apply to start a network (Blueprint 19, W-01 step 1; Paper "Authentication
// v2" 13). Turnstile runs here before anything is stored or emailed; the
// application goes to the Edge with the app-server secret. Every accepted
// form ends on the same "Application received" page (no enumeration).

import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { readApplication } from '#lib/founders.js';
import { FoundersApi } from '#lib/server/apis-founders.js';
import { failureOf, isBackendError } from '#lib/server/flow.js';
import { humanCheck, turnstileSiteKey } from '#lib/server/human-check.js';
import { runApi } from '#lib/server/request.js';
import { turnstileMessage } from '#lib/server/turnstile.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	const session = await locals.session();
	return {
		turnstileSiteKey: turnstileSiteKey(),
		// A signed-in person without approval comes here from "Start a network".
		signedInEmail: session?.email ?? null
	};
};

export const actions: Actions = {
	default: async (event) => {
		const form = await event.request.formData();
		const parsed = readApplication(form);
		if (!parsed.ok) return fail(400, { values: parsed.values, errors: parsed.errors });

		const human = await humanCheck(event, form, 'apply');
		if (!human.ok) {
			return fail(human.reason === 'unavailable' ? 503 : 400, {
				values: parsed.values,
				message: turnstileMessage(human)
			});
		}

		const exit = await runApi(
			event,
			null,
			Effect.gen(function* () {
				return yield* (yield* FoundersApi).apply(parsed.request);
			})
		);
		if (Exit.isFailure(exit)) {
			const failure = failureOf(exit);
			const message = isBackendError(failure, 'rate_limited')
				? 'Too many applications right now. Try again in a few minutes.'
				: isBackendError(failure, 'validation_error')
					? 'Check your details and try again.'
					: 'We couldn’t send your application right now. Try again shortly.';
			return fail(isBackendError(failure, 'rate_limited') ? 429 : 503, {
				values: parsed.values,
				message
			});
		}
		redirect(303, '/apply/sent');
	}
};
