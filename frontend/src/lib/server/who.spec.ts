import { describe, expect, it } from 'vitest';
import type { Cookies } from '@sveltejs/kit';
import { clearWho, whoValue, WHO_COOKIE, writeWho } from './who';

type Set = { name: string; value: string; options: Record<string, unknown> };

function fakeCookies() {
	const sets: Set[] = [];
	const deletes: { name: string; options: Record<string, unknown> }[] = [];
	const cookies = {
		set: (name: string, value: string, options: Record<string, unknown>) =>
			sets.push({ name, value, options }),
		delete: (name: string, options: Record<string, unknown>) => deletes.push({ name, options })
	} as unknown as Cookies;
	return { cookies, sets, deletes };
}

const UID = '11111111-1111-4111-8111-111111111111';
const MEMBERSHIP = '22222222-2222-4222-8222-222222222222';

describe('ew_who (Blueprint 20 B6)', () => {
	it('is the first 16 bytes of HMAC-SHA256(secret, uid:membership), base64url', async () => {
		const value = await whoValue('secret', UID, MEMBERSHIP);
		expect(value).toMatch(/^[A-Za-z0-9_-]{22}$/);
		// Independent check with node:crypto.
		const { createHmac } = await import('node:crypto');
		const expected = createHmac('sha256', 'secret')
			.update(`${UID}:${MEMBERSHIP}`)
			.digest()
			.subarray(0, 16)
			.toString('base64url');
		expect(value).toBe(expected);
	});

	it('differs per person, per workspace and per secret, and holds no ids', async () => {
		const a = await whoValue('secret', UID, MEMBERSHIP);
		expect(await whoValue('secret', MEMBERSHIP, UID)).not.toBe(a);
		expect(await whoValue('secret', UID, UID)).not.toBe(a);
		expect(await whoValue('other', UID, MEMBERSHIP)).not.toBe(a);
		expect(a).not.toContain(UID.slice(0, 8));
	});

	it('is readable by the page, Lax, path /, Secure on https, 7 days', async () => {
		const { cookies, sets } = fakeCookies();
		await writeWho(cookies, 'secret', UID, MEMBERSHIP, true);
		expect(sets).toEqual([
			{
				name: WHO_COOKIE,
				value: await whoValue('secret', UID, MEMBERSHIP),
				options: { path: '/', sameSite: 'lax', secure: true, httpOnly: false, maxAge: 604800 }
			}
		]);
	});

	it('clears instead of writing when the secret is missing', async () => {
		const { cookies, sets, deletes } = fakeCookies();
		await writeWho(cookies, undefined, UID, MEMBERSHIP, false);
		expect(sets).toEqual([]);
		expect(deletes).toEqual([{ name: WHO_COOKIE, options: { path: '/' } }]);
		clearWho(cookies);
		expect(deletes).toHaveLength(2);
	});
});
