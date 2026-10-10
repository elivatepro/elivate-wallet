// Wizard step 0, Welcome (Paper 01): the network, office and role the
// invitation bound, no choices (W-02 step 1). Readable before the PIN.

import { redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { IdentityApi } from '#lib/server/apis-identity.js';
import { failureOf, redirectForFailure } from '#lib/server/flow.js';
import { loadWizard, stepTotal } from '#lib/server/onboarding.js';
import { runApi } from '#lib/server/request.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const wizard = await loadWizard(event);
	const membershipId = wizard.membershipId;
	if (!membershipId) redirect(303, '/onboarding/continue');
	const exit = await runApi(
		event,
		wizard.session,
		Effect.gen(function* () {
			return yield* (yield* IdentityApi).welcome(membershipId);
		})
	);
	if (Exit.isFailure(exit)) {
		const failure = failureOf(exit);
		if (failure._tag === 'BackendError' && failure.code === 'workspace_invalid') {
			redirect(303, '/onboarding/continue');
		}
		redirectForFailure(failure);
	}
	return { workspace: exit.value, total: stepTotal(wizard.level), light: wizard.level === 'light' };
};
