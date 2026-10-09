// Shared parsing and copy for the email + password forms. Messages are reviewed
// client copy keyed by failure kind; sign-in never says which part was wrong
// (W-01), sign-up never reveals whether an address already has an account.

import type { AuthFailure } from '#lib/server/auth.js';

export const MIN_PASSWORD = 8; // backend/supabase/config.toml minimum_password_length
export const MAX_PASSWORD = 72; // bcrypt input limit used by Supabase Auth
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export type CredentialErrors = Partial<Record<'email' | 'password', string>>;

export function readCredentials(
	form: FormData
):
	| { ok: true; email: string; password: string }
	| { ok: false; email: string; errors: CredentialErrors } {
	const email = String(form.get('email') ?? '')
		.trim()
		.toLowerCase();
	const password = String(form.get('password') ?? '');
	const errors: CredentialErrors = {};
	if (!EMAIL.test(email) || email.length > 254) errors.email = 'Enter a valid email address.';
	if (password.length === 0) errors.password = 'Enter your password.';
	else if (password.length > MAX_PASSWORD) errors.password = 'That password is too long.';
	return Object.keys(errors).length > 0
		? { ok: false, email, errors }
		: { ok: true, email, password };
}

/** Email only (forgot password). Same rule as readCredentials. */
export function readEmail(
	form: FormData
): { ok: true; email: string } | { ok: false; email: string; error: string } {
	const email = String(form.get('email') ?? '')
		.trim()
		.toLowerCase();
	return EMAIL.test(email) && email.length <= 254
		? { ok: true, email }
		: { ok: false, email, error: 'Enter a valid email address.' };
}

/** A new password (recovery): same limits as sign-up. Null when acceptable. */
export function newPasswordError(password: string): string | null {
	if (password.length < MIN_PASSWORD) return `Use at least ${MIN_PASSWORD} characters.`;
	if (password.length > MAX_PASSWORD) return 'That password is too long.';
	return null;
}

export function authMessage(
	kind: AuthFailure['kind'],
	form: 'sign-in' | 'sign-up' | 'recovery'
): string {
	switch (kind) {
		case 'invalid_credentials':
			return 'We couldn’t sign you in. Check your details and try again.';
		case 'email_not_confirmed':
			return 'Confirm your email first. The link is in your inbox.';
		case 'weak_password':
			return `Use at least ${MIN_PASSWORD} characters.`;
		case 'rate_limited':
			return 'Too many attempts. Wait a few minutes, then try again.';
		case 'link_invalid':
			return 'This link has expired or was already used.';
		case 'unavailable':
			return form === 'sign-in'
				? 'We couldn’t sign you in right now. Try again shortly.'
				: form === 'recovery'
					? 'We couldn’t send reset instructions right now. Try again shortly.'
					: 'We couldn’t create your account right now. Try again shortly.';
	}
}
