// Wizard step 5, all set (Paper 13): identity, payout account, PIN.
import { Effect, Exit } from 'effect';
import { PayoutApi } from '#lib/server/apis-identity.js';
import { expectStep } from '#lib/server/onboarding.js';
import { runApi } from '#lib/server/request.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'done');
	const profile = wizard.profile!;
	const membershipId = wizard.membershipId;
	let account: { bankName: string | null; accountLast4: string } | null = null;
	if (membershipId) {
		const exit = await runApi(
			event,
			wizard.session,
			Effect.gen(function* () {
				return yield* (yield* PayoutApi).accounts(membershipId);
			})
		);
		const active = Exit.isSuccess(exit) ? exit.value.find((a) => a.status === 'active') : undefined;
		if (active) account = { bankName: active.bankName, accountLast4: active.accountLast4 };
	}
	return {
		firstName: profile.displayName ?? profile.firstName,
		identity: profile.identity.method === 'leader_review' ? 'Confirmed by a leader' : 'Verified',
		account
	};
};
