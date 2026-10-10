// Blueprint 20 B6: the readable, non-secret cache guard. `ew_who` is a keyed
// hash of the user id and membership id, so the browser can tell whether its
// device cache belongs to the person and workspace now signed in without
// learning either id. It is not an authenticator: the server never reads it.

import type { Cookies } from '@sveltejs/kit';

export const WHO_COOKIE = 'ew_who';

/** Same lifetime as the workspace cookie (cookies.ts). */
const WHO_MAX_AGE = 60 * 60 * 24 * 7;

const encoder = new TextEncoder();

const base64url = (bytes: Uint8Array): string =>
	btoa(String.fromCharCode(...bytes))
		.replaceAll('+', '-')
		.replaceAll('/', '_')
		.replace(/=+$/, '');

/** base64url(first 16 bytes of HMAC-SHA256(secret, uid + ':' + membershipId)). */
export async function whoValue(secret: string, uid: string, membershipId: string): Promise<string> {
	const key = await crypto.subtle.importKey(
		'raw',
		encoder.encode(secret),
		{ name: 'HMAC', hash: 'SHA-256' },
		false,
		['sign']
	);
	const mac = await crypto.subtle.sign('HMAC', key, encoder.encode(`${uid}:${membershipId}`));
	return base64url(new Uint8Array(mac).slice(0, 16));
}

/**
 * Sets the guard for this person and workspace. Without a secret it clears
 * it instead, so the client simply shows no cached data (fails closed).
 */
export async function writeWho(
	cookies: Cookies,
	secret: string | undefined,
	uid: string,
	membershipId: string,
	secure: boolean
): Promise<void> {
	if (!secret) return clearWho(cookies);
	cookies.set(WHO_COOKIE, await whoValue(secret, uid, membershipId), {
		path: '/',
		sameSite: 'lax',
		secure,
		httpOnly: false,
		maxAge: WHO_MAX_AGE
	});
}

export function clearWho(cookies: Cookies): void {
	cookies.delete(WHO_COOKIE, { path: '/' });
}
