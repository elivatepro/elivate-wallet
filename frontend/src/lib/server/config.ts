import {
	SUPABASE_PUBLISHABLE_KEY,
	SUPABASE_URL,
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
} {
	return {
		siteKey: TURNSTILE_SITE_KEY ?? null,
		secret: TURNSTILE_SECRET_KEY,
		url: TURNSTILE_SITEVERIFY_URL
	};
}
