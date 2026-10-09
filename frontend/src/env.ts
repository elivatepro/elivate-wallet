import { defineEnvVars } from '@sveltejs/kit/env';

// Server-only configuration. In the hybrid model (decision 36) the browser never
// talks to Supabase, so neither value is public. Both may be absent at build
// time (the prerendered app shell needs neither); the server fails closed when
// a request needs them and they are missing.
const optionalUrl = (value: string | undefined): string | undefined => {
	if (value === undefined || value === '') return undefined;
	const url = new URL(value);
	if (url.protocol !== 'https:' && url.hostname !== '127.0.0.1' && url.hostname !== 'localhost') {
		throw new Error('SUPABASE_URL must use https outside local development');
	}
	return url.origin;
};

export const variables = defineEnvVars({
	SUPABASE_URL: {
		description: 'Supabase project API origin (local: http://127.0.0.1:54321).',
		schema: optionalUrl
	},
	SUPABASE_PUBLISHABLE_KEY: {
		description: 'Supabase publishable (anon) key. Never a secret or service-role key.',
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	},
	// Cloudflare Turnstile on sign-in, sign-up and forgot-password (Blueprint 10).
	// Worker secrets on the deployed app; Cloudflare's documented test keys for
	// local development and e2e. Missing keys fail closed (the forms refuse).
	TURNSTILE_SITE_KEY: {
		description: 'Turnstile widget site key (public; rendered into the auth forms).',
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	},
	TURNSTILE_SITEVERIFY_URL: {
		description:
			'Local e2e only: a loopback siteverify stand-in. Anything else is refused; unset uses Cloudflare.',
		schema: (value: string | undefined) => {
			if (value === undefined || value === '') return undefined;
			const url = new URL(value);
			if (url.hostname !== '127.0.0.1' && url.hostname !== 'localhost') {
				throw new Error('TURNSTILE_SITEVERIFY_URL may only point at a local stand-in');
			}
			return url.toString();
		}
	},
	TURNSTILE_HOSTNAMES: {
		description:
			'Comma-separated hostnames a Turnstile token may come from. Empty refuses every token.',
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	},
	E2E_GEO_HEADERS: {
		description:
			'Local e2e only ("1"): take the sign-in location from x-e2e-city / x-e2e-country. Ignored unless SUPABASE_URL is a loopback address.',
		schema: (value: string | undefined) => value === '1'
	},
	TURNSTILE_SECRET_KEY: {
		description: 'Turnstile secret key for server-side siteverify. Never sent to the browser.',
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	}
});
