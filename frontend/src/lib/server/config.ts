import { SUPABASE_PUBLISHABLE_KEY, SUPABASE_URL } from '$app/env/private';

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
