// Platform Admin presentation helpers (Blueprint 18): labels, badge tones and
// WAT date formatting. Client-safe: no secrets, no server imports.

import type { NetworkState, RestoreStatus, SwitchKey } from '#lib/contract/admin.js';

export type Tone = 'success' | 'warning' | 'danger' | 'info' | 'neutral' | 'accent';

export const NETWORK_TONES: Readonly<Record<NetworkState, Tone>> = {
	active: 'success',
	trial: 'info',
	paused: 'warning',
	pending_payment: 'neutral',
	deactivated: 'danger'
};

export const ACCOUNT_STATUS_LABELS = {
	active: 'Active',
	restricted: 'Restricted',
	suspended: 'Suspended',
	deactivated: 'Deactivated'
} as const;

export const ACCOUNT_TONES: Readonly<Record<keyof typeof ACCOUNT_STATUS_LABELS, Tone>> = {
	active: 'success',
	restricted: 'info',
	suspended: 'warning',
	deactivated: 'neutral'
};

export const RESTORE_LABELS: Readonly<Record<RestoreStatus, string>> = {
	requested: 'Requested',
	validating: 'Validating',
	in_review: 'In review',
	restoring: 'Restoring',
	completed: 'Completed',
	rejected: 'Rejected',
	cancelled: 'Cancelled',
	failed: 'Failed'
};

export const RESTORE_TONES: Readonly<Record<RestoreStatus, Tone>> = {
	requested: 'neutral',
	validating: 'info',
	in_review: 'warning',
	restoring: 'accent',
	completed: 'success',
	rejected: 'neutral',
	cancelled: 'neutral',
	failed: 'danger'
};

export const OPEN_RESTORE: ReadonlySet<RestoreStatus> = new Set([
	'requested',
	'validating',
	'in_review',
	'restoring'
]);

/** Paper "Admin — Screens v1" A12/A11b switch order. */
export const SWITCH_ORDER: readonly SwitchKey[] = [
	'withdrawals',
	'transfers',
	'payouts',
	'conversion',
	'income',
	'adjustments',
	'reversals',
	'returned_funds'
];

export const ROLE_NAMES = {
	member: 'Member',
	team_leader: 'Team Leader',
	director: 'Director',
	world_team_member: 'World Team',
	president_team_member: 'President'
} as const;

const WAT = 'Africa/Lagos';

const dayFormat = new Intl.DateTimeFormat('en-GB', {
	day: 'numeric',
	month: 'short',
	year: 'numeric',
	timeZone: WAT
});
const shortDay = new Intl.DateTimeFormat('en-GB', {
	day: 'numeric',
	month: 'short',
	timeZone: WAT
});
const timeFormat = new Intl.DateTimeFormat('en-GB', {
	hour: '2-digit',
	minute: '2-digit',
	hour12: false,
	timeZone: WAT
});
const keyFormat = new Intl.DateTimeFormat('en-CA', {
	year: 'numeric',
	month: '2-digit',
	day: '2-digit',
	timeZone: WAT
});

/** "11 Mar 2027" (WAT). */
export const day = (iso: string | null | undefined): string =>
	iso ? dayFormat.format(new Date(iso)) : '—';

/** "Today 07:41", "Yesterday 18:20", else "3 Oct" (WAT). */
export function when(iso: string | null | undefined, now = new Date()): string {
	if (!iso) return 'Never';
	const at = new Date(iso);
	const key = keyFormat.format(at);
	if (key === keyFormat.format(now)) return `Today ${timeFormat.format(at)}`;
	if (key === keyFormat.format(new Date(now.getTime() - 86_400_000))) {
		return `Yesterday ${timeFormat.format(at)}`;
	}
	return at.getFullYear() === now.getFullYear() ? shortDay.format(at) : dayFormat.format(at);
}

/** Two-letter initials for avatar tiles. */
export function initials(name: string | null | undefined, fallback = '?'): string {
	const words = (name ?? '').trim().split(/\s+/).filter(Boolean);
	if (words.length === 0) return fallback;
	return (
		(words[0]?.[0] ?? '') + (words.length > 1 ? (words.at(-1)?.[0] ?? '') : '')
	).toUpperCase();
}

/** "Partner pilot" etc. — audit action names as words: kill_switch.stopped → "Kill switch stopped". */
export function actionLabel(action: string): string {
	const words = action.replace(/[._]/g, ' ').trim();
	return words.charAt(0).toUpperCase() + words.slice(1);
}

/** Section keys as words: returned_funds → "Returned funds". */
export const sectionLabel = (section: string): string => actionLabel(section);

/** Builds a URL for the same page with some query values changed (null removes). */
export function withQuery(url: URL, changes: Record<string, string | null>): string {
	const next = new URL(url);
	for (const [key, value] of Object.entries(changes)) {
		if (value === null || value === '') next.searchParams.delete(key);
		else next.searchParams.set(key, value);
	}
	const query = next.searchParams.toString();
	return `${next.pathname}${query ? `?${query}` : ''}`;
}
