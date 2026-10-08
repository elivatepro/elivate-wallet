import type { SupabaseClient } from '@supabase/supabase-js';
import type { VerifiedSession } from '#lib/server/auth.js';
import type { Theme } from '#lib/theme.js';

declare global {
	namespace App {
		interface Locals {
			/** Per-request Supabase Auth client (server only; cookies are HttpOnly). */
			supabase: () => SupabaseClient;
			/** Verified session, memoized per request; null when signed out. */
			session: () => Promise<VerifiedSession | null>;
			theme: Theme;
			secureCookies: boolean;
		}
	}
}

export {};
