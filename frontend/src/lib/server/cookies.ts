// Non-auth cookies. The workspace cookie is not a permission (A-02): the server
// re-validates it on every call and clears it on `workspace_invalid`.

import type { Cookies } from '@sveltejs/kit';
import { UUID_PATTERN } from '#lib/contract/common.js';
import { INVITATION_TOKEN_PATTERN } from '#lib/contract/invitations.js';
import { parseTheme, type Theme } from '#lib/theme.js';

export const WORKSPACE_COOKIE = 'ew_ws';
export const THEME_COOKIE = 'ew_theme';
export const JOIN_COOKIE = 'ew_join';
export const JOIN_PASSWORD_COOKIE = 'ew_join_pw';

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

// Invitation join flow (W-02, Blueprint 03 B2 "Link"). The link carries its
// token in the URL fragment; the join page posts it once and the server keeps
// it here, HttpOnly, so it survives the Auth email round trip without ever
// entering a URL, log or Referer. It is not authentication: acceptance still
// needs a verified session whose email matches. It outlives sign-out on
// purpose, so a person signed in as someone else can switch accounts.

const JOIN_MAX_AGE = 60 * 60 * 24 * 7; // the link's own lifetime (Q2)

export function readJoinToken(cookies: Cookies): string | null {
	const value = cookies.get(JOIN_COOKIE);
	return value && INVITATION_TOKEN_PATTERN.test(value) ? value : null;
}

export function writeJoinToken(cookies: Cookies, token: string, secure: boolean): void {
	cookies.set(JOIN_COOKIE, token, { ...base(secure), httpOnly: true, maxAge: JOIN_MAX_AGE });
}

export function clearJoin(cookies: Cookies): void {
	cookies.delete(JOIN_COOKIE, { path: '/' });
	cookies.delete(JOIN_PASSWORD_COOKIE, { path: '/' });
}

/**
 * Set when the join flow's verification email created the account (its link is
 * a sign-up confirmation), so the join page asks for a first password.
 */
export function markJoinPasswordNeeded(cookies: Cookies, secure: boolean): void {
	cookies.set(JOIN_PASSWORD_COOKIE, '1', { ...base(secure), httpOnly: true, maxAge: 60 * 60 });
}

export function joinPasswordNeeded(cookies: Cookies): boolean {
	return cookies.get(JOIN_PASSWORD_COOKIE) === '1';
}

export function clearJoinPasswordNeeded(cookies: Cookies): void {
	cookies.delete(JOIN_PASSWORD_COOKIE, { path: '/' });
}

// Password recovery (Blueprint 10). Set when a Recovery link was confirmed on
// /auth/confirm, so /reset-password knows this session came from that email.
// Not authentication: the Auth session itself is what lets the password
// change. Short-lived and HttpOnly; cleared once the new password is saved.
export const RECOVERY_COOKIE = 'ew_recovery';

export function markRecovery(cookies: Cookies, secure: boolean): void {
	cookies.set(RECOVERY_COOKIE, '1', { ...base(secure), httpOnly: true, maxAge: 60 * 15 });
}

export function recoveryPending(cookies: Cookies): boolean {
	return cookies.get(RECOVERY_COOKIE) === '1';
}

/**
 * Blueprint 14: the new password is saved; /reset-password then shows the
 * Z10 confirmation (other devices signed out, PIN next) instead of the form,
 * and the form can no longer be submitted. Expires with the recovery window.
 */
export function markRecoverySaved(cookies: Cookies, secure: boolean): void {
	cookies.set(RECOVERY_COOKIE, 'saved', { ...base(secure), httpOnly: true, maxAge: 60 * 15 });
}

export function recoverySaved(cookies: Cookies): boolean {
	return cookies.get(RECOVERY_COOKIE) === 'saved';
}

export function clearRecovery(cookies: Cookies): void {
	cookies.delete(RECOVERY_COOKIE, { path: '/' });
}
