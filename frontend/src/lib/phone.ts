import { PHONE_PATTERN } from '#lib/contract/identity.js';

/** "803 214 5678", "08032145678" or "+2348032145678" → +234XXXXXXXXXX. */
export function normalisePhone(raw: string): string | null {
	const trimmed = raw.trim();
	const digits = trimmed.replace(/\D/g, '');
	if (!digits) return null;
	const full = trimmed.startsWith('+')
		? `+${digits}`
		: digits.startsWith('234')
			? `+${digits}`
			: `+234${digits.replace(/^0/, '')}`;
	return PHONE_PATTERN.test(full) && full.length >= 14 ? full : null;
}
