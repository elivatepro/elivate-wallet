// SupabaseAuth (plan §5.2, §7.6): server-only, one client per request, session
// held in HttpOnly cookies written by @supabase/ssr. Uses the publishable key
// only. The browser never sees an access or refresh token.

import type { Cookies } from '@sveltejs/kit';
import { createServerClient } from '@supabase/ssr';
import type { SupabaseClient } from '@supabase/supabase-js';
import { Data } from 'effect';

export interface AuthConfig {
	readonly supabaseUrl: string;
	readonly publishableKey: string;
	readonly secureCookies: boolean;
	readonly fetch: typeof globalThis.fetch;
}

export function createAuthClient(cookies: Cookies, config: AuthConfig): SupabaseClient {
	const cookieDefaults = {
		path: '/',
		httpOnly: true,
		secure: config.secureCookies,
		sameSite: 'lax' as const
	};
	return createServerClient(config.supabaseUrl, config.publishableKey, {
		cookieOptions: { ...cookieDefaults, name: 'ew-auth' },
		cookies: {
			getAll: () => cookies.getAll(),
			setAll: (toSet) => {
				for (const { name, value, options } of toSet) {
					// Never let a library default weaken the cookie: HttpOnly always.
					cookies.set(name, value, { ...options, ...cookieDefaults });
				}
			}
		},
		// @supabase/ssr always uses PKCE; email links use token_hash + verifyOtp, which needs no verifier.
		auth: { detectSessionInUrl: false, autoRefreshToken: false },
		global: { fetch: config.fetch }
	});
}

export interface VerifiedSession {
	readonly userId: string;
	readonly email: string | null;
	readonly accessToken: string;
}

/**
 * Returns the verified session or null. Claims are verified with getClaims()
 * (signature/JWKS, or the Auth server), never trusted from the cookie alone.
 */
export async function verifiedSession(supabase: SupabaseClient): Promise<VerifiedSession | null> {
	const { data, error } = await supabase.auth.getClaims();
	const claims = data?.claims;
	if (error || !claims || typeof claims.sub !== 'string') return null;
	const { data: sessionData } = await supabase.auth.getSession();
	const accessToken = sessionData.session?.access_token;
	if (!accessToken) return null;
	return {
		userId: claims.sub,
		email: typeof claims.email === 'string' ? claims.email : null,
		accessToken
	};
}

/** Auth failures the UI distinguishes (plan §5.2). */
export class AuthFailure extends Data.TaggedError('AuthFailure')<{
	readonly kind:
		| 'invalid_credentials'
		| 'email_not_confirmed'
		| 'weak_password'
		| 'rate_limited'
		| 'link_invalid'
		| 'unavailable';
}> {}

export function authFailureFrom(error: { code?: string; status?: number } | null): AuthFailure {
	switch (error?.code) {
		case 'invalid_credentials':
			return new AuthFailure({ kind: 'invalid_credentials' });
		case 'email_not_confirmed':
			return new AuthFailure({ kind: 'email_not_confirmed' });
		case 'weak_password':
			return new AuthFailure({ kind: 'weak_password' });
		case 'over_request_rate_limit':
		case 'over_email_send_rate_limit':
			return new AuthFailure({ kind: 'rate_limited' });
		case 'otp_expired':
		case 'otp_disabled':
		case 'flow_state_expired':
		case 'flow_state_not_found':
		case 'bad_code_verifier':
			return new AuthFailure({ kind: 'link_invalid' });
		default:
			if (error?.status === 429) return new AuthFailure({ kind: 'rate_limited' });
			return new AuthFailure({ kind: 'unavailable' });
	}
}
