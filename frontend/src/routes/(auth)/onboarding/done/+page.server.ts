// Wizard all set (Paper 13): identity, payout account, PIN. Blueprint 22: the
// light setup (President Team, directors whose funds are not managed) shows
// the profile and the PIN only.
import { Effect, Exit } from 'effect';
import { PayoutApi } from '#lib/server/apis-identity.js';
import { expectStep, readNext, stepTotal } from '#lib/server/onboarding.js';
import { runApi } from '#lib/server/request.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'done');
	const profile = wizard.profile!;
	const membershipId = wizard.walletMembershipId;
	let account: { bankName: string | null; accountLast4: string } | null = null;
	if (wizard.level === 'wallet' && membershipId) {
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
		light: wizard.level !== 'wallet',
		total: stepTotal(wizard.level),
		firstName: profile.displayName ?? profile.firstName,
		identity:
			profile.identity.status !== 'verified'
				? null
				: profile.identity.method === 'leader_review'
					? 'Confirmed by a leader'
					: 'Verified',
		account,
		/** A founder goes on to name their network (Blueprint 22). */
		toSetup: readNext(event.cookies)?.startsWith('/setup') ?? false
	};
};
