// Wizard step 2 confirmation (Paper 08): the legal name locked from the NIN
// record (or confirmed by a leader) and, when the record had one, the phone.
import { expectStep } from '#lib/server/onboarding.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'profile', 'bank', 'done');
	const profile = wizard.profile!;
	return {
		identity: profile.identity,
		phone: profile.phoneSource === 'nin' ? profile.phone : null
	};
};
