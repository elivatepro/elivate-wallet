import { describe, expect, it } from 'vitest';
import { SITEVERIFY_URL, TURNSTILE_FIELD, verifyTurnstile } from './turnstile';

const form = (token?: string) => {
	const data = new FormData();
	if (token !== undefined) data.set(TURNSTILE_FIELD, token);
	return data;
};

function fakeFetch(answer: unknown, status = 200) {
	const calls: { url: string; body: FormData; redirect: RequestRedirect | undefined }[] = [];
	const fetch = (async (url: string, init: RequestInit) => {
		calls.push({ url, body: init.body as FormData, redirect: init.redirect });
		return new Response(JSON.stringify(answer), { status });
	}) as unknown as typeof globalThis.fetch;
	return { fetch, calls };
}

const HOST = 'app.elivatewallet.com';
const hostnames = [HOST];

describe('verifyTurnstile', () => {
	it('fails closed without a secret', async () => {
		const { fetch, calls } = fakeFetch({ success: true });
		expect(
			await verifyTurnstile({ secret: undefined, fetch, hostnames }, form('t'), 'sign-in', null)
		).toEqual({ ok: false, reason: 'unavailable' });
		expect(calls).toHaveLength(0);
	});

	it('refuses a missing or oversized token without calling Cloudflare', async () => {
		const { fetch, calls } = fakeFetch({ success: true });
		const config = { secret: 's', fetch, hostnames };
		expect(await verifyTurnstile(config, form(), 'sign-in', null)).toEqual({
			ok: false,
			reason: 'missing'
		});
		expect(await verifyTurnstile(config, form('x'.repeat(2049)), 'sign-in', null)).toEqual({
			ok: false,
			reason: 'missing'
		});
		expect(calls).toHaveLength(0);
	});

	it('posts secret, token and IP to siteverify and accepts success', async () => {
		const { fetch, calls } = fakeFetch({ success: true, action: 'sign-up', hostname: HOST });
		const outcome = await verifyTurnstile(
			{ secret: 's3cret', fetch, hostnames },
			form('tok'),
			'sign-up',
			'1.2.3.4'
		);
		expect(outcome).toEqual({ ok: true });
		expect(calls[0]?.url).toBe(SITEVERIFY_URL);
		// Cloudflare Workers throw on redirect: 'error'.
		expect(calls[0]?.redirect).toBe('manual');
		expect(calls[0]?.body.get('secret')).toBe('s3cret');
		expect(calls[0]?.body.get('response')).toBe('tok');
		expect(calls[0]?.body.get('remoteip')).toBe('1.2.3.4');
	});

	it('rejects failures and tokens minted for another form', async () => {
		const failed = fakeFetch({ success: false, 'error-codes': ['invalid-input-response'] });
		expect(
			await verifyTurnstile(
				{ secret: 's', fetch: failed.fetch, hostnames },
				form('t'),
				'sign-in',
				null
			)
		).toEqual({ ok: false, reason: 'rejected' });
		const other = fakeFetch({ success: true, action: 'sign-up', hostname: HOST });
		expect(
			await verifyTurnstile(
				{ secret: 's', fetch: other.fetch, hostnames },
				form('t'),
				'sign-in',
				null
			)
		).toEqual({ ok: false, reason: 'rejected' });
	});

	it('treats an unreachable or malformed siteverify as unavailable', async () => {
		const down = fakeFetch({}, 500);
		expect(
			await verifyTurnstile(
				{ secret: 's', fetch: down.fetch, hostnames },
				form('t'),
				'sign-in',
				null
			)
		).toEqual({ ok: false, reason: 'unavailable' });
		const moved = fakeFetch({ success: true }, 302);
		expect(
			await verifyTurnstile(
				{ secret: 's', fetch: moved.fetch, hostnames },
				form('t'),
				'sign-in',
				null
			)
		).toEqual({ ok: false, reason: 'unavailable' });
		const odd = fakeFetch({ success: 'yes' });
		expect(
			await verifyTurnstile(
				{ secret: 's', fetch: odd.fetch, hostnames },
				form('t'),
				'sign-in',
				null
			)
		).toEqual({ ok: false, reason: 'unavailable' });
	});

	it('refuses a token from a hostname not on the allowlist', async () => {
		const elsewhere = fakeFetch({ success: true, action: 'sign-in', hostname: 'evil.example' });
		expect(
			await verifyTurnstile(
				{ secret: 's', fetch: elsewhere.fetch, hostnames },
				form('t'),
				'sign-in',
				null
			)
		).toEqual({ ok: false, reason: 'rejected' });
		const unnamed = fakeFetch({ success: true, action: 'sign-in' });
		expect(
			await verifyTurnstile(
				{ secret: 's', fetch: unnamed.fetch, hostnames },
				form('t'),
				'sign-in',
				null
			)
		).toEqual({ ok: false, reason: 'rejected' });
		const listed = fakeFetch({ success: true, action: 'sign-in', hostname: HOST });
		expect(
			await verifyTurnstile(
				{ secret: 's', fetch: listed.fetch, hostnames: [] },
				form('t'),
				'sign-in',
				null
			)
		).toEqual({ ok: false, reason: 'rejected' });
	});
});
