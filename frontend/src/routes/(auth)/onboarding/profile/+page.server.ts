// Wizard profile step (W-02 step 5; Paper 09 profile, 10 rank wheel). Wallet
// setup: required photo, phone when the NIN record had none, self-declared
// rank. Blueprint 22, light setup (no wallet): first and last name (until a
// NIN locks them), photo and rank; no phone. The backend requires the photo,
// so it is always asked for. Multipart POST, so it works before JavaScript.

import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { RANKS } from '#lib/contract/identity.js';
import { normalisePhone } from '#lib/phone.js';
import { IdentityApi, type ProfileChanges } from '#lib/server/apis-identity.js';
import { failureOf, isBackendError, redirectForFailure } from '#lib/server/flow.js';
import { expectStep, stepNumber, stepTotal } from '#lib/server/onboarding.js';
import { storePhoto } from '#lib/server/photos.js';
import { runApi } from '#lib/server/request.js';
import { newIdempotencyKey } from '#lib/server/workspace.js';
import type { Actions, PageServerLoad } from './$types';

/** Names are asked for only in the light setup, and only while no NIN locks them. */
const asksNames = (light: boolean, verified: boolean) => light && !verified;

const cleanName = (value: FormDataEntryValue | null) =>
	String(value ?? '')
		.trim()
		.replace(/\s+/g, ' ');

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'profile', 'bank', 'done');
	const profile = wizard.profile!;
	const light = wizard.level !== 'wallet';
	return {
		light,
		step: stepNumber('profile', wizard.level),
		total: stepTotal(wizard.level),
		names: asksNames(light, profile.identity.status === 'verified'),
		firstName: profile.firstName,
		lastName: profile.lastName,
		hasPhoto: profile.hasPhoto,
		photoUpdatedAt: profile.photoUpdatedAt,
		phone: profile.phone,
		phoneLocked: profile.phoneSource === 'nin',
		rank: profile.rank
	};
};

export const actions: Actions = {
	default: async (event) => {
		const { wizard } = await expectStep(event, 'profile', 'bank', 'done');
		const profile = wizard.profile!;
		const light = wizard.level !== 'wallet';
		const names = asksNames(light, profile.identity.status === 'verified');
		const form = await event.request.formData();
		const photo = form.get('photo');
		const rank = String(form.get('rank') ?? '');
		const firstName = cleanName(form.get('firstName'));
		const lastName = cleanName(form.get('lastName'));
		const phoneLocked = profile.phoneSource === 'nin';
		const phone = light
			? null
			: phoneLocked
				? profile.phone
				: normalisePhone(String(form.get('phone') ?? ''));
		const echo = { rank, firstName, lastName };

		const errors: Record<string, string> = {};
		const hasUpload = photo instanceof File && photo.size > 0;
		if (!hasUpload && !profile.hasPhoto) errors.photo = 'Add a profile photo.';
		if (names && (!firstName || firstName.length > 80)) errors.firstName = 'Enter your first name.';
		if (names && (!lastName || lastName.length > 80)) errors.lastName = 'Enter your last name.';
		if (!light && !phone) errors.phone = 'Enter your phone number.';
		if (!(RANKS as readonly string[]).includes(rank)) errors.rank = 'Choose your rank.';
		if (Object.keys(errors).length) return fail(400, { errors, ...echo });

		if (hasUpload) {
			const stored = await storePhoto(event, wizard.session, photo);
			if (!stored.ok) {
				if ('error' in stored) return fail(400, { errors: { photo: stored.error }, ...echo });
				redirectForFailure(stored.failure);
			}
		}

		const changes: ProfileChanges = {
			rank,
			...(names ? { firstName, lastName } : {}),
			...(light || phoneLocked ? {} : { phone: phone! })
		};
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
			const messages: Record<string, string> = {
				phone: 'Enter a valid phone number.',
				firstName: 'Enter your first name.',
				lastName: 'Enter your last name.'
			};
			const key = field in messages ? field : 'rank';
			return fail(400, { errors: { [key]: messages[key] ?? 'Choose your rank.' }, ...echo });
		}
		// The NIN landed meanwhile (name_locked): the page asks again without names.
		if (isBackendError(failure, 'conflict')) redirect(303, '/onboarding/profile');
		redirectForFailure(failure);
	}
};
