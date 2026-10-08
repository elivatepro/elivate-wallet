// Wizard step 2, identity (W-02 step 3; Paper 04 verify, 05 checking, 06 not
// verified, 07 leader review). The NIN only passes through: the server never
// keeps or echoes it except back into the field the person typed it in.

import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { NIN_PATTERN } from '#lib/contract/identity.js';
import { IdentityApi } from '#lib/server/apis-identity.js';
import { failureOf, isBackendError, redirectForFailure } from '#lib/server/flow.js';
import { expectStep } from '#lib/server/onboarding.js';
import { runApi } from '#lib/server/request.js';
import { newIdempotencyKey } from '#lib/server/workspace.js';
import type { Actions, PageServerLoad } from './$types';

const digits = (value: FormDataEntryValue | null) => String(value ?? '').replace(/\s/g, '');

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'identity');
	const identity = wizard.profile!.identity;
	const wantsReview = event.url.searchParams.has('review') && identity.failedChecks > 0;
	return {
		identity,
		mode:
			identity.status === 'review_pending'
				? ('waiting' as const)
				: identity.checksRemaining === 0 || wantsReview
					? ('review' as const)
					: ('verify' as const),
		canReview: wizard.membershipId !== null,
		idempotencyKey: newIdempotencyKey()
	};
};

export const actions: Actions = {
	verify: async (event) => {
		const { wizard } = await expectStep(event, 'identity');
		const nin = digits((await event.request.formData()).get('nin'));
		if (!NIN_PATTERN.test(nin)) return fail(400, { nin, error: 'Enter the 11-digit NIN.' });
		const exit = await runApi(
			event,
			wizard.session,
			Effect.gen(function* () {
				return yield* (yield* IdentityApi).verifyNin(nin);
			})
		);
		if (Exit.isSuccess(exit)) redirect(303, '/onboarding/details');
		const failure = failureOf(exit);
		if (isBackendError(failure, 'nin_not_verified')) {
			const left = Number(failure._tag === 'BackendError' ? failure.details.checksRemaining : 0);
			if (left <= 0) redirect(303, '/onboarding/identity');
			return fail(422, { nin, failed: true, error: 'This NIN didn’t match a national ID record.' });
		}
		if (isBackendError(failure, 'nin_review_required')) redirect(303, '/onboarding/identity');
		if (isBackendError(failure, 'nin_in_use')) {
			return fail(409, {
				nin,
				message: 'This NIN can’t be used on this account. Contact Elivate support.'
			});
		}
		if (isBackendError(failure, 'conflict')) redirect(303, '/onboarding/continue');
		if (isBackendError(failure, 'validation_error')) {
			return fail(400, { nin, error: 'Enter the 11-digit NIN.' });
		}
		if (isBackendError(failure, 'provider_unavailable') || failure._tag === 'TransportError') {
			return fail(503, {
				nin,
				message: 'We couldn’t reach the ID check right now. Try again shortly.'
			});
		}
		redirectForFailure(failure);
	},

	review: async (event) => {
		const { wizard } = await expectStep(event, 'identity');
		const form = await event.request.formData();
		const values = {
			nin: digits(form.get('nin')),
			givenName: String(form.get('givenName') ?? '').trim(),
			middleNames: String(form.get('middleNames') ?? '')
				.trim()
				.split(/\s+/)
				.filter(Boolean),
			surname: String(form.get('surname') ?? '').trim(),
			idempotencyKey: String(form.get('idempotencyKey') ?? '')
		};
		const echo = {
			review: true,
			nin: values.nin,
			givenName: values.givenName,
			middleNames: values.middleNames.join(' '),
			surname: values.surname
		};
		const errors: Record<string, string> = {};
		if (!NIN_PATTERN.test(values.nin)) errors.nin = 'Enter the 11-digit NIN.';
		if (!values.givenName || values.givenName.length > 80)
			errors.givenName = 'Enter your first name.';
		if (!values.surname || values.surname.length > 80) errors.surname = 'Enter your surname.';
		if (values.middleNames.length > 4) errors.middleNames = 'At most four middle names.';
		if (Object.keys(errors).length) return fail(400, { ...echo, errors });
		const membershipId = wizard.membershipId;
		if (!membershipId)
			return fail(409, { ...echo, message: 'Open your network first, then ask again.' });

		const exit = await runApi(
			event,
			wizard.session,
			Effect.gen(function* () {
				return yield* (yield* IdentityApi).requestReview(membershipId, values);
			})
		);
		if (Exit.isSuccess(exit)) redirect(303, '/onboarding/identity');
		const failure = failureOf(exit);
		if (isBackendError(failure, 'nin_in_use')) {
			return fail(409, {
				...echo,
				message: 'This NIN can’t be used on this account. Contact Elivate support.'
			});
		}
		if (isBackendError(failure, 'conflict')) redirect(303, '/onboarding/continue');
		if (failure._tag === 'TransportError' && failure.status !== 401) {
			return fail(503, { ...echo, message: 'We couldn’t confirm that. Try again.' });
		}
		redirectForFailure(failure);
	}
};
