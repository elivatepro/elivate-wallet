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
	/**
	 * The browser's User-Agent, forwarded so Auth records the real device for
	 * Devices & sessions (Blueprint 10). No IP is forwarded.
	 */
	readonly userAgent?: string | null;
	/**
	 * Blueprint 18: the admin site keeps its own session in `ew-admin-auth`
	 * (SameSite=Strict, host-only), never shared with the Wallet app's `ew-auth`.
	 */
	readonly surface?: 'member' | 'admin';
}

/** The auth cookie name (and chunk prefix) of each site. */
export const AUTH_COOKIE = { member: 'ew-auth', admin: 'ew-admin-auth' } as const;

export function createAuthClient(cookies: Cookies, config: AuthConfig): SupabaseClient {
	const surface = config.surface ?? 'member';
	const cookieDefaults = {
		path: '/',
		httpOnly: true,
		secure: config.secureCookies,
		sameSite: surface === 'admin' ? ('strict' as const) : ('lax' as const)
	};
	const name = AUTH_COOKIE[surface];
	return createServerClient(config.supabaseUrl, config.publishableKey, {
		cookieOptions: { ...cookieDefaults, name },
		cookies: {
			// Each site reads only its own session cookies.
			getAll: () =>
				cookies
					.getAll()
					.filter((c) => (surface === 'admin') === c.name.startsWith(AUTH_COOKIE.admin)),
			setAll: (toSet) => {
				for (const { name, value, options } of toSet) {
					// Never let a library default weaken the cookie: HttpOnly always.
					cookies.set(name, value, { ...options, ...cookieDefaults });
				}
			}
		},
		// @supabase/ssr always uses PKCE; email links use token_hash + verifyOtp, which needs no verifier.
		auth: { detectSessionInUrl: false, autoRefreshToken: false },
		global: {
			fetch: config.fetch,
			...(config.userAgent ? { headers: { 'user-agent': config.userAgent.slice(0, 300) } } : {})
		}
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
