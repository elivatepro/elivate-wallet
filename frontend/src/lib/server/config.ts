import {
	APP_SERVER_SECRET,
	APP_SURFACE,
	CHATWOOT_BASE_URL,
	CHATWOOT_HMAC_TOKEN,
	CHATWOOT_WEBSITE_TOKEN,
	E2E_GEO_HEADERS,
	E2E_LOCAL_EXPORTS,
	EXPORTS_WORKER_SECRET,
	PUSH_VAPID_PUBLIC_KEY,
	SUPABASE_PUBLISHABLE_KEY,
	SUPABASE_URL,
	TURNSTILE_HOSTNAMES,
	TURNSTILE_SECRET_KEY,
	TURNSTILE_SITE_KEY,
	TURNSTILE_SITEVERIFY_URL
} from '$app/env/private';

export interface ServerConfig {
	readonly supabaseUrl: string;
	readonly publishableKey: string;
}

/** Fails closed when the deployment is missing configuration. */
export function requireConfig(): ServerConfig {
	if (!SUPABASE_URL) throw new Error('SUPABASE_URL is not configured');
	if (!SUPABASE_PUBLISHABLE_KEY) throw new Error('SUPABASE_PUBLISHABLE_KEY is not configured');
	return { supabaseUrl: SUPABASE_URL, publishableKey: SUPABASE_PUBLISHABLE_KEY };
}

/** Blueprint 42: the key browsers subscribe to push with; null when not set up. */
export const pushPublicKey = (): string | null => PUSH_VAPID_PUBLIC_KEY ?? null;

/**
 * Turnstile keys (Blueprint 10). Either may be missing: the page then renders
 * no widget and the action refuses (verifyTurnstile fails closed).
 */
export function turnstileConfig(): {
	siteKey: string | null;
	secret: string | undefined;
	/** Loopback stand-in for local e2e only (env.ts refuses anything else). */
	url: string | undefined;
	/** Hostnames siteverify may report; empty refuses every token. */
	hostnames: readonly string[];
} {
	return {
		siteKey: TURNSTILE_SITE_KEY ?? null,
		secret: TURNSTILE_SECRET_KEY,
		url: TURNSTILE_SITEVERIFY_URL,
		hostnames: (TURNSTILE_HOSTNAMES ?? '')
			.split(',')
			.map((host) => host.trim().toLowerCase())
			.filter((host) => host.length > 0)
	};
}

/**
 * Blueprint 14: local e2e may supply the sign-in location in headers, and only
 * against a loopback Supabase. The deployed Worker always uses Cloudflare's.
 */
export function geoTestHeaders(): boolean {
	if (E2E_GEO_HEADERS !== true || !SUPABASE_URL) return false;
	const host = new URL(SUPABASE_URL).hostname;
	return host === '127.0.0.1' || host === 'localhost';
}

/** Blueprint 14: the secret the security function requires for sign-in records. */
export const appServerSecret = (): string | undefined => APP_SERVER_SECRET;

/** Blueprint 15: the export runner's shared secret (Worker secret; Vault and Edge hold the same). */
export const exportsWorkerSecret = (): string | undefined => EXPORTS_WORKER_SECRET;

/**
 * Blueprint 15: local e2e stores files on disk and renders with Playwright's
 * Chromium, only against a loopback Supabase. The deployed Worker uses R2 and
 * Browser Rendering.
 */
export function localExportsDir(): string | null {
	if (!E2E_LOCAL_EXPORTS || !SUPABASE_URL) return null;
	const host = new URL(SUPABASE_URL).hostname;
	return host === '127.0.0.1' || host === 'localhost' ? E2E_LOCAL_EXPORTS : null;
}

/**
 * Blueprint 17: Chatwoot Cloud (W-21). Null when the inbox is not configured,
 * so Start a chat can say chat is unavailable instead of pretending.
 */
export function chatwootConfig(): {
	baseUrl: string;
	websiteToken: string;
	hmacToken: string;
} | null {
	if (!CHATWOOT_WEBSITE_TOKEN || !CHATWOOT_HMAC_TOKEN) return null;
	return {
		baseUrl: CHATWOOT_BASE_URL ?? 'https://app.chatwoot.com',
		websiteToken: CHATWOOT_WEBSITE_TOKEN,
		hmacToken: CHATWOOT_HMAC_TOKEN
	};
}

/** Blueprint 18: the site a request belongs to. */
export type Surface = 'member' | 'admin';

/**
 * The Worker's surface for this path. `both` (local e2e against a loopback
 * Supabase only) splits by path; anywhere else it falls back to `member`.
 */
export function surfaceFor(pathname: string): Surface {
	const isAdminPath = pathname === '/admin' || pathname.startsWith('/admin/');
	if (APP_SURFACE === 'admin') return 'admin';
	if (APP_SURFACE === 'both' && SUPABASE_URL) {
		const host = new URL(SUPABASE_URL).hostname;
		if (host === '127.0.0.1' || host === 'localhost') return isAdminPath ? 'admin' : 'member';
	}
	return 'member';
}

/** Where the Wallet app is (gate pages link there to set or reset the PIN). */
export const walletUrl = (): string =>
	APP_SURFACE === 'both' ? '/sign-in' : 'https://app.elivatewallet.com';
