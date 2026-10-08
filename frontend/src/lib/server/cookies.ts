// Non-auth cookies. The workspace cookie is not a permission (A-02): the server
// re-validates it on every call and clears it on `workspace_invalid`.

import type { Cookies } from '@sveltejs/kit';
import { UUID_PATTERN } from '#lib/contract/common.js';
import { parseTheme, type Theme } from '#lib/theme.js';

export const WORKSPACE_COOKIE = 'ew_ws';
export const THEME_COOKIE = 'ew_theme';

const base = (secure: boolean) => ({ path: '/', sameSite: 'lax' as const, secure });

export function readWorkspace(cookies: Cookies): string | null {
	const value = cookies.get(WORKSPACE_COOKIE);
	return value && UUID_PATTERN.test(value) ? value : null;
}

export function writeWorkspace(cookies: Cookies, membershipId: string, secure: boolean): void {
	cookies.set(WORKSPACE_COOKIE, membershipId, {
		...base(secure),
		httpOnly: true,
		maxAge: 60 * 60 * 24 * 7
	});
}

export function clearWorkspace(cookies: Cookies): void {
	cookies.delete(WORKSPACE_COOKIE, { path: '/' });
}

export function readTheme(cookies: Cookies): Theme {
	return parseTheme(cookies.get(THEME_COOKIE));
}

export function writeTheme(cookies: Cookies, theme: Theme, secure: boolean): void {
	// Not sensitive; readable by the client so the shell can follow it.
	cookies.set(THEME_COOKIE, theme, {
		...base(secure),
		httpOnly: false,
		maxAge: 60 * 60 * 24 * 365
	});
}
