// Cloudflare Turnstile, verified server-side in the auth form actions
// (Blueprint 10, owner decision 2026-10-08: sign-in, sign-up, forgot-password).
// The widget's token arrives as the `cf-turnstile-response` form field and is
// checked once with siteverify before anything reaches Supabase Auth. Missing
// configuration fails closed. Tokens and the secret are never logged.

import { Schema } from 'effect';

export const TURNSTILE_FIELD = 'cf-turnstile-response';
export const SITEVERIFY_URL = 'https://challenges.cloudflare.com/turnstile/v0/siteverify';
/** Turnstile tokens are at most 2048 characters. */
const MAX_TOKEN = 2048;

export type TurnstileAction = 'sign-in' | 'sign-up' | 'forgot-password';

const SiteverifyResponse = Schema.Struct({
	success: Schema.Boolean,
	action: Schema.optionalKey(Schema.String),
	hostname: Schema.optionalKey(Schema.String)
});

export type TurnstileOutcome =
	/** Passed: continue with the form. */
	| { readonly ok: true }
	/** No token, expired, or rejected: the person retries the check. */
	| { readonly ok: false; readonly reason: 'missing' | 'rejected' }
	/** Not configured or Cloudflare unreachable: refuse, try again later. */
	| { readonly ok: false; readonly reason: 'unavailable' };

export interface TurnstileConfig {
	readonly secret: string | undefined;
	readonly fetch: typeof globalThis.fetch;
	/** Defaults to Cloudflare's siteverify. */
	readonly url?: string | undefined;
	/** Hostnames the token may come from; empty refuses every token. */
	readonly hostnames: readonly string[];
}

export async function verifyTurnstile(
	config: TurnstileConfig,
	form: FormData,
	action: TurnstileAction,
	remoteIp: string | null
): Promise<TurnstileOutcome> {
	if (!config.secret) return { ok: false, reason: 'unavailable' };
	const token = form.get(TURNSTILE_FIELD);
	if (typeof token !== 'string' || token.length === 0 || token.length > MAX_TOKEN) {
		return { ok: false, reason: 'missing' };
	}

	const body = new FormData();
	body.set('secret', config.secret);
	body.set('response', token);
	if (remoteIp) body.set('remoteip', remoteIp);
	body.set('idempotency_key', crypto.randomUUID());

	let parsed: typeof SiteverifyResponse.Type;
	try {
		const response = await config.fetch(config.url ?? SITEVERIFY_URL, {
			method: 'POST',
			body,
			signal: AbortSignal.timeout(8_000),
			redirect: 'error'
		});
		if (!response.ok) return { ok: false, reason: 'unavailable' };
		parsed = Schema.decodeUnknownSync(SiteverifyResponse)(await response.json());
	} catch {
		return { ok: false, reason: 'unavailable' };
	}
	if (!parsed.success) return { ok: false, reason: 'rejected' };
	// A token solved on a site not on this deployment's allowlist is refused.
	if (!parsed.hostname || !config.hostnames.includes(parsed.hostname.toLowerCase())) {
		return { ok: false, reason: 'rejected' };
	}
	// The widget names its form; a token minted for another form is refused.
	// (Cloudflare's test keys answer without an action, so empty is allowed.)
	if (parsed.action && parsed.action !== action) return { ok: false, reason: 'rejected' };
	return { ok: true };
}

/** Reviewed copy for a failed check (never says why in detail). */
export function turnstileMessage(outcome: Exclude<TurnstileOutcome, { ok: true }>): string {
	return outcome.reason === 'unavailable'
		? 'We couldn’t run the security check right now. Try again shortly.'
		: 'Complete the security check, then try again.';
}
