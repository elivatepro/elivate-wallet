// Founder application form (Blueprint 19, Paper "Authentication v2" 13):
// parsing with the same rules as the database, and display helpers the Admin
// app shares.

import {
	EMAIL_PATTERN,
	FOUNDER_PHONE_PATTERN,
	FOUNDER_RANKS,
	type FounderApplicationRequest,
	type FounderRank
} from '#lib/contract/founders.js';

export type ApplicationField = 'fullName' | 'email' | 'phone' | 'teamName' | 'rank';
export type ApplicationErrors = Partial<Record<ApplicationField, string>>;
export type ApplicationValues = Record<ApplicationField, string>;

const squash = (value: FormDataEntryValue | null) =>
	String(value ?? '')
		.trim()
		.replace(/\s+/g, ' ');

const length = (value: string) => [...value].length;

export function readApplication(
	form: FormData
):
	| { ok: true; values: ApplicationValues; request: FounderApplicationRequest }
	| { ok: false; values: ApplicationValues; errors: ApplicationErrors } {
	const values: ApplicationValues = {
		fullName: squash(form.get('fullName')),
		email: squash(form.get('email')).toLowerCase(),
		phone: squash(form.get('phone')),
		teamName: squash(form.get('teamName')),
		rank: squash(form.get('rank'))
	};
	const phone = values.phone.replace(/[\s().-]/g, '');
	const errors: ApplicationErrors = {};
	if (length(values.fullName) < 2 || length(values.fullName) > 100) {
		errors.fullName = 'Enter your full name.';
	}
	if (!EMAIL_PATTERN.test(values.email) || values.email.length > 254) {
		errors.email = 'Enter a valid email address.';
	}
	if (!FOUNDER_PHONE_PATTERN.test(phone)) errors.phone = 'Enter a phone number, digits only.';
	if (length(values.teamName) < 2 || length(values.teamName) > 100) {
		errors.teamName = 'Use 2–100 characters.';
	}
	if (!(FOUNDER_RANKS as readonly string[]).includes(values.rank)) {
		errors.rank = 'Choose your rank.';
	}
	if (Object.keys(errors).length > 0) return { ok: false, values, errors };
	return {
		ok: true,
		values,
		request: {
			fullName: values.fullName,
			email: values.email,
			phone,
			teamName: values.teamName,
			rank: values.rank as FounderRank
		}
	};
}

/** "08035550142" → "0803 555 0142"; other numbers are shown as stored. */
export function formatPhone(phone: string): string {
	const local = /^0([0-9]{3})([0-9]{3})([0-9]{4})$/.exec(phone);
	if (local) return `0${local[1]} ${local[2]} ${local[3]}`;
	const intl = /^\+234([0-9]{3})([0-9]{3})([0-9]{4})$/.exec(phone);
	if (intl) return `+234 ${intl[1]} ${intl[2]} ${intl[3]}`;
	return phone;
}
