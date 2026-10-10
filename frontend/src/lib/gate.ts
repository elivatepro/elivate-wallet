// Session-gate routing (plan §5.7). `account_blocked` arrives as an error, not a
// gate value; both forms map to a page here.

import type { Gate } from '#lib/contract/security.js';

export const GATE_PATHS = {
	pin_setup_required: '/pin/setup',
	pin_required: '/pin',
	pin_locked: '/pin/locked',
	ready: '/workspaces'
} as const satisfies Record<Gate, string>;

export const BLOCKED_PATH = '/blocked';
export const SIGN_IN_PATH = '/sign-in';

/** Error codes that move the person to a gate page instead of showing an error. */
export function pathForGateCode(code: string): string | null {
	switch (code) {
		case 'authentication_required':
			return SIGN_IN_PATH;
		case 'pin_setup_required':
			return GATE_PATHS.pin_setup_required;
		case 'pin_required':
			return GATE_PATHS.pin_required;
		case 'pin_locked':
			return GATE_PATHS.pin_locked;
		case 'account_blocked':
			return BLOCKED_PATH;
		default:
			return null;
	}
}

/**
 * Accepts only same-origin relative paths for `next` redirects (no scheme,
 * no protocol-relative `//`, no backslashes), so a crafted link cannot send
 * someone off-site after they sign in.
 */
export function safeNext(value: string | null | undefined): string | null {
	if (!value || !value.startsWith('/') || value.startsWith('//') || value.includes('\\')) {
		return null;
	}
	if (value.length > 400) return null;
	return value;
}

/**
 * A `next` that may only return to a page of the signed-in app (/app or
 * /app/…): the gate pages (PIN, workspace picker, sign-in) send the person
 * back there once they are through (slice 21).
 */
export function safeAppNext(value: string | null | undefined): string | null {
	const next = safeNext(value);
	if (!next || [...next].some((c) => c.charCodeAt(0) < 0x20)) return null;
	const path = next.split(/[?#]/)[0] ?? '';
	return path === '/app' || path.startsWith('/app/') ? next : null;
}

/** `path` with `?next=` (or `&next=`) for a safe app page; `path` alone otherwise. */
export function withNext(path: string, next: string | null | undefined): string {
	const safe = safeAppNext(next);
	if (!safe) return path;
	return `${path}${path.includes('?') ? '&' : '?'}next=${encodeURIComponent(safe)}`;
}
