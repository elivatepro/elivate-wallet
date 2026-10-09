// Where a sign-in came from (Blueprint 14): the IP Cloudflare saw
// (CF-Connecting-IP, set by Cloudflare at the edge) and the approximate city
// and country of the Worker request's `cf` object. Pure, so it is unit-tested;
// anything malformed becomes null rather than reaching the backend.

export interface ClientContext {
	readonly ip: string | null;
	readonly city: string | null;
	readonly country: string | null;
}

export interface CfLocation {
	readonly city?: unknown;
	readonly country?: unknown;
}

const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
const IPV6 = /^[0-9A-Fa-f:.]{2,45}$/;
const COUNTRY = /^[A-Z][A-Z0-9]$/;
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f]/;

function ipOf(value: string | null): string | null {
	const ip = value?.trim() ?? '';
	return IPV4.test(ip) || (ip.includes(':') && IPV6.test(ip)) ? ip : null;
}

function cityOf(value: unknown): string | null {
	if (typeof value !== 'string') return null;
	const city = value.trim();
	return city.length > 0 && [...city].length <= 100 && !CONTROL.test(city) ? city : null;
}

function countryOf(value: unknown): string | null {
	return typeof value === 'string' && COUNTRY.test(value) ? value : null;
}

/**
 * Where the request came from. `cf` is the Worker request's location (absent
 * outside Cloudflare); `testHeaders` lets local e2e set it in headers.
 */
export function clientContext(
	headers: Headers,
	cf: CfLocation | undefined,
	testHeaders: boolean
): ClientContext {
	const ip = ipOf(headers.get('cf-connecting-ip'));
	if (testHeaders) {
		return {
			ip,
			city: cityOf(headers.get('x-e2e-city')),
			country: countryOf(headers.get('x-e2e-country'))
		};
	}
	return { ip, city: cityOf(cf?.city), country: countryOf(cf?.country) };
}
