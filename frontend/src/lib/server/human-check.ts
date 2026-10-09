// The auth forms' Turnstile step (Blueprint 10): reads the keys and the
// visitor's IP (Cloudflare's CF-Connecting-IP; absent in local dev) and runs
// verifyTurnstile. Kept apart from turnstile.ts so that module stays pure.

import type { RequestEvent } from '@sveltejs/kit';
import { turnstileConfig } from './config';
import { verifyTurnstile, type TurnstileAction, type TurnstileOutcome } from './turnstile';

export function humanCheck(
	event: RequestEvent,
	form: FormData,
	action: TurnstileAction
): Promise<TurnstileOutcome> {
	const config = turnstileConfig();
	return verifyTurnstile(
		{ secret: config.secret, fetch: event.fetch, url: config.url, hostnames: config.hostnames },
		form,
		action,
		event.request.headers.get('cf-connecting-ip')
	);
}

/** The widget's public site key for the page (null renders no widget). */
export const turnstileSiteKey = (): string | null => turnstileConfig().siteKey;
