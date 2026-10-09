import {
	E2E_GEO_HEADERS,
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
