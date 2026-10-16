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
	APP_SERVER_SECRET: {
		description:
			'Shared secret only this app server holds; lets it record sign-ins (Blueprint 14). Missing: no sign-in history is written.',
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	},
	E2E_GEO_HEADERS: {
		description:
			'Local e2e only ("1"): take the sign-in location from x-e2e-city / x-e2e-country. Ignored unless SUPABASE_URL is a loopback address.',
		schema: (value: string | undefined) => value === '1'
	},
	EXPORTS_WORKER_SECRET: {
		description:
			'Shared secret of the export runner (Blueprint 15): pg_cron/pg_net calls /internal/exports/run with it, and the runner calls the exports-worker Edge Function with it. Missing: no files are made.',
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	},
	E2E_LOCAL_EXPORTS: {
		description:
			"Local e2e only: a directory for generated files, rendered with Playwright's Chromium instead of the R2 and Browser Rendering bindings. Ignored unless SUPABASE_URL is a loopback address.",
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	},
	// Support chat (Blueprint 17, W-21): Chatwoot Cloud's website inbox. The
	// widget token is public; the HMAC token signs the UID (identity validation)
	// and never leaves the server. Missing: Start a chat says chat is unavailable.
	CHATWOOT_WEBSITE_TOKEN: {
		description: 'Chatwoot website inbox token (public; loaded into the widget on demand).',
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	},
	CHATWOOT_HMAC_TOKEN: {
		description:
			'Chatwoot identity-validation secret for the website inbox. Server only; signs the UID.',
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	},
	CHATWOOT_BASE_URL: {
		description: 'Chatwoot origin (default https://app.chatwoot.com). Must be https.',
		schema: (value: string | undefined) => {
			if (value === undefined || value === '') return undefined;
			const url = new URL(value);
			if (url.protocol !== 'https:') throw new Error('CHATWOOT_BASE_URL must use https');
			return url.origin;
		}
	},
	// Blueprint 18: one codebase, two Workers. `member` (default) serves the
	// Wallet app; `admin` serves only /admin/* (admin.elivatewallet.com).
	// `both` is for local e2e only and is refused unless SUPABASE_URL is a
	// loopback address (config.ts).
	APP_SURFACE: {
		description:
			'Which site this Worker serves: member (default), admin, or both (local e2e only).',
		schema: (value: string | undefined) => {
			if (value === undefined || value === '') return 'member' as const;
			if (value === 'member' || value === 'admin' || value === 'both') return value;
			throw new Error('APP_SURFACE must be member, admin or both');
		}
	},
	// Blueprint 42: Web Push. The VAPID public key is public (the browser
	// subscribes with it; a Worker var in wrangler.jsonc); its private half is
	// an Edge secret of the outbox worker. Missing: the switch says push is off.
	PUSH_VAPID_PUBLIC_KEY: {
		description: 'Web Push VAPID public key (base64url, 65 bytes; public).',
		schema: (value: string | undefined) => {
			if (value === undefined || value === '') return undefined;
			if (!/^B[A-Za-z0-9_-]{86}$/.test(value))
				throw new Error('PUSH_VAPID_PUBLIC_KEY is malformed');
			return value;
		}
	},
	TURNSTILE_SECRET_KEY: {
		description: 'Turnstile secret key for server-side siteverify. Never sent to the browser.',
		schema: (value: string | undefined) => (value === '' ? undefined : value)
	}
});
