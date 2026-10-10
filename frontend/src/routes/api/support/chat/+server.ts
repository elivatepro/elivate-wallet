// Support chat (Blueprint 17, W-21; Paper WK01): what the browser needs to
// open Elivate's Chatwoot chat, loaded only when someone presses Start a chat.
// Shares only the UID (signed for Chatwoot identity validation, so nobody can
// pose as someone else), the network name and, from the browser, the screen.
// Never names, emails, money, bank details, evidence, PINs or tokens.
import { Effect } from 'effect';
import { SecurityApi } from '#lib/server/apis.js';
import { SettingsApi } from '#lib/server/apis-settings.js';
import { chatwootConfig } from '#lib/server/config.js';
import { relayRead } from '#lib/server/money-endpoints.js';
import type { RequestHandler } from './$types';

async function sign(secret: string, value: string): Promise<string> {
	const key = await crypto.subtle.importKey(
		'raw',
		new TextEncoder().encode(secret),
		{ name: 'HMAC', hash: 'SHA-256' },
		false,
		['sign']
	);
	const mac = new Uint8Array(
		await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(value))
	);
	return Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
}

export const GET: RequestHandler = (event) =>
	relayRead(event, {}, (membershipId) =>
		Effect.gen(function* () {
			const config = chatwootConfig();
			if (!config) return { available: false as const };
			const state = yield* (yield* SecurityApi).state;
			const brand = yield* (yield* SettingsApi).brand(membershipId);
			const identifierHash = yield* Effect.promise(() => sign(config.hmacToken, state.uid));
			return {
				available: true as const,
				baseUrl: config.baseUrl,
				websiteToken: config.websiteToken,
				identifier: state.uid,
				identifierHash,
				network: brand.name
			};
		})
	);
