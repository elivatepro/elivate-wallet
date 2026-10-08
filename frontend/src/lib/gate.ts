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
	if (value.length > 200) return null;
	return value;
}
