// Elivate support chat (Blueprint 17, W-21; Paper WK01). Chatwoot Cloud loads
// only when someone presses Start a chat: no third-party script on any other
// page. Chatwoot learns the UID (identity-validated with the server's HMAC),
// the network name and the current screen's route pattern, never names,
// emails, money, bank details, evidence, PINs or tokens.

import { Effect, Exit } from 'effect';
import { SupportChat } from '#lib/contract/settings.js';
import { getJson } from './api';

/** Chatwoot's own launcher stays hidden: our Start a chat button opens it. */
export interface ChatwootSettings {
	readonly hideMessageBubble: boolean;
	readonly position: 'left' | 'right';
	readonly type: 'standard' | 'expanded_bubble';
	readonly launcherTitle: string;
	readonly darkMode: 'auto' | 'light';
}

interface ChatwootApi {
	setUser(identifier: string, user: { identifier_hash: string }): void;
	setCustomAttributes(attributes: Record<string, string>): void;
	toggle(state?: 'open' | 'close'): void;
}

interface ChatwootSdk {
	run(options: { websiteToken: string; baseUrl: string }): void;
}

declare global {
	interface Window {
		chatwootSettings?: ChatwootSettings;
		chatwootSDK?: ChatwootSdk;
		$chatwoot?: ChatwootApi;
	}
}

export const CHATWOOT_SETTINGS: ChatwootSettings = {
	hideMessageBubble: true,
	position: 'right',
	type: 'standard',
	launcherTitle: 'Chat with support',
	darkMode: 'auto'
};

export const SUPPORT_EMAIL = 'support@elivatewallet.com';

/** How long the widget may take to say it is ready before we stop waiting. */
const READY_TIMEOUT_MS = 15_000;

/**
 * The screen Chatwoot sees: the route pattern only ("/app/members/[id]"),
 * never a query string, hash or the value of an id.
 */
export function chatScreen(routeId: string | null | undefined): string {
	const path = (routeId ?? '').split(/[?#]/)[0] ?? '';
	const clean = path.replace(/[^A-Za-z0-9/_\-[\]().]/g, '').slice(0, 120);
	return clean.startsWith('/') ? clean : '/app';
}

/** The SDK URL on Chatwoot's origin; null for anything but https (or local http). */
export function sdkUrl(baseUrl: string): string | null {
	let url: URL;
	try {
		url = new URL(baseUrl);
	} catch {
		return null;
	}
	const local = url.hostname === '127.0.0.1' || url.hostname === 'localhost';
	if (url.protocol !== 'https:' && !(local && url.protocol === 'http:')) return null;
	return `${url.origin}/packs/js/sdk.js`;
}

type Ready = { readonly baseUrl: string; readonly websiteToken: string };

let loading: Promise<boolean> | null = null;
let loadedFor: string | null = null;

function loadWidget({ baseUrl, websiteToken }: Ready): Promise<boolean> {
	const src = sdkUrl(baseUrl);
	if (!src) return Promise.resolve(false);
	if (loading && loadedFor === src) return loading;
	loadedFor = src;
	loading = new Promise<boolean>((resolve) => {
		const script = document.createElement('script');
		let done = false;
		const finish = (ok: boolean) => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			window.removeEventListener('chatwoot:ready', onReady);
			if (!ok) {
				// Let a later press try again from scratch.
				script.remove();
				loading = null;
				loadedFor = null;
			}
			resolve(ok);
		};
		const onReady = () => finish(true);
		const timer = setTimeout(() => finish(false), READY_TIMEOUT_MS);
		window.addEventListener('chatwoot:ready', onReady);

		window.chatwootSettings = { ...CHATWOOT_SETTINGS };
		script.src = src;
		script.async = true;
		script.defer = true;
		script.onload = () => {
			try {
				window.chatwootSDK?.run({ websiteToken, baseUrl: new URL(src).origin });
				if (!window.chatwootSDK) finish(false);
			} catch {
				finish(false);
			}
		};
		script.onerror = () => finish(false);
		document.head.appendChild(script);
	});
	return loading;
}

/**
 * Start a chat: read the chat settings, load Chatwoot once, identify the
 * person by UID only and open the panel. False means chat is not available
 * (unconfigured, offline, blocked or failed); the caller says so honestly.
 */
export async function openSupportChat(screen: string): Promise<boolean> {
	const exit = await Effect.runPromiseExit(getJson('/api/support/chat', SupportChat));
	if (!Exit.isSuccess(exit) || !exit.value.available) return false;
	const chat = exit.value;
	const ready = await loadWidget(chat);
	const api = window.$chatwoot;
	if (!ready || !api) return false;
	try {
		api.setUser(chat.identifier, { identifier_hash: chat.identifierHash });
		api.setCustomAttributes({ uid: chat.identifier, network: chat.network, screen });
		api.toggle('open');
		return true;
	} catch {
		return false;
	}
}
