import { describe, expect, it } from 'vitest';
import { clientContext } from './client-context';

const headers = (values: Record<string, string>) => new Headers(values);

describe('clientContext (Blueprint 14)', () => {
	it('takes the IP from CF-Connecting-IP and the place from the Worker cf object', () => {
		expect(
			clientContext(
				headers({ 'cf-connecting-ip': '102.89.1.10', 'x-e2e-city': 'Elsewhere' }),
				{ city: 'Lagos', country: 'NG' },
				false
			)
		).toEqual({ ip: '102.89.1.10', city: 'Lagos', country: 'NG' });
	});

	it('accepts IPv6 and has no place outside Cloudflare', () => {
		expect(clientContext(headers({ 'cf-connecting-ip': '2001:db8::1' }), undefined, false)).toEqual(
			{ ip: '2001:db8::1', city: null, country: null }
		);
	});

	it('drops anything malformed instead of sending it', () => {
		expect(
			clientContext(
				headers({ 'cf-connecting-ip': '999.1.1.1' }),
				{ city: 'La\ngos', country: 'Nigeria' },
				false
			)
		).toEqual({ ip: null, city: null, country: null });
		expect(clientContext(headers({}), { city: 'x'.repeat(101), country: 7 }, false)).toEqual({
			ip: null,
			city: null,
			country: null
		});
	});

	it('reads the e2e headers only when allowed', () => {
		const h = headers({ 'x-e2e-city': 'Abuja', 'x-e2e-country': 'NG' });
		expect(clientContext(h, undefined, true)).toEqual({ ip: null, city: 'Abuja', country: 'NG' });
		expect(clientContext(h, undefined, false)).toEqual({ ip: null, city: null, country: null });
	});
});
