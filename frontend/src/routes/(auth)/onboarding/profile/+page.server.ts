// Wizard step 3, profile (W-02 step 5; Paper 09 profile, 10 rank wheel):
// required photo, phone when the NIN record had none, self-declared rank.
// Multipart POST, so it works before JavaScript.

import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { RANKS } from '#lib/contract/identity.js';
import { normalisePhone } from '#lib/phone.js';
import { IdentityApi, type ProfileChanges } from '#lib/server/apis-identity.js';
import { failureOf, isBackendError, redirectForFailure } from '#lib/server/flow.js';
import { expectStep } from '#lib/server/onboarding.js';
import { storePhoto } from '#lib/server/photos.js';
import { runApi } from '#lib/server/request.js';
import { newIdempotencyKey } from '#lib/server/workspace.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'profile', 'bank', 'done');
	const profile = wizard.profile!;
	return {
		hasPhoto: profile.hasPhoto,
		photoRequired: wizard.photoRequired,
		phone: profile.phone,
		phoneLocked: profile.phoneSource === 'nin',
		rank: profile.rank
	};
};

export const actions: Actions = {
	default: async (event) => {
		const { wizard } = await expectStep(event, 'profile', 'bank', 'done');
		const profile = wizard.profile!;
		const form = await event.request.formData();
		const photo = form.get('photo');
		const rank = String(form.get('rank') ?? '');
		const phoneLocked = profile.phoneSource === 'nin';
		const phone = phoneLocked ? profile.phone : normalisePhone(String(form.get('phone') ?? ''));

		const errors: Record<string, string> = {};
		const hasUpload = photo instanceof File && photo.size > 0;
		if (wizard.photoRequired && !hasUpload && !profile.hasPhoto)
			errors.photo = 'Add a profile photo.';
		if (!phone) errors.phone = 'Enter your phone number.';
		if (!(RANKS as readonly string[]).includes(rank)) errors.rank = 'Choose your rank.';
		if (Object.keys(errors).length) return fail(400, { errors, rank });

		if (hasUpload && wizard.photoRequired) {
			const stored = await storePhoto(event, wizard.session, photo);
			if (!stored.ok) {
				if ('error' in stored) return fail(400, { errors: { photo: stored.error }, rank });
				redirectForFailure(stored.failure);
			}
		}

		const changes: ProfileChanges = { rank, ...(phoneLocked ? {} : { phone: phone! }) };
		const exit = await runApi(
			event,
			wizard.session,
			Effect.gen(function* () {
				return yield* (yield* IdentityApi).updateProfile(changes, newIdempotencyKey());
			})
		);
		if (Exit.isSuccess(exit)) redirect(303, '/onboarding/continue');
		const failure = failureOf(exit);
		if (isBackendError(failure, 'validation_error')) {
			const field = failure._tag === 'BackendError' ? String(failure.details.field) : '';
			return fail(400, {
				errors:
					field === 'phone'
						? { phone: 'Enter a valid phone number.' }
						: { rank: 'Choose your rank.' },
				rank
			});
		}
		redirectForFailure(failure);
	}
};
