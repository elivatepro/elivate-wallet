// Elivate support chat (Blueprint 17, W-21; Paper WK01). Chatwoot Cloud loads
// only when someone presses Start a chat: no third-party script on any other
// page. Chatwoot learns the UID (identity-validated with the server's HMAC).
// Slice 34 (owner decision 2026-10-11): also the name, email and account
// context from the server, plus from this browser the screen the person came
// from, their device, the app version and the last error the app showed.
// Never money, bank details, evidence, PINs or tokens.

import { Effect, Exit } from 'effect';
import { SupportChat } from '#lib/contract/settings.js';
import { observeReplies } from '#lib/contract/transport.js';
import { getJson } from './api';

/** Chatwoot's own launcher stays hidden: our Start a chat button opens it. */
export interface ChatwootSettings {
	readonly hideMessageBubble: boolean;
	readonly position: 'left' | 'right';
	readonly type: 'standard' | 'expanded_bubble';
	readonly launcherTitle: string;
	readonly darkMode: 'auto' | 'light';
}

/**
 * Chatwoot's setUser throws unless the user object has one of `avatar_url`,
 * `email` or `name`, so a person without a name yet is named by the UID.
 */
export interface ChatwootUser {
	readonly name: string;
	readonly email?: string;
	readonly identifier_hash: string;
}

/** Chatwoot contact attributes (keys defined in the Chatwoot account). */
export type ChatAttributes = Record<string, string | boolean>;

export interface ChatwootApi {
	setUser(identifier: string, user: ChatwootUser): void;
	setCustomAttributes(attributes: ChatAttributes): void;
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
 * Slice 34: the screen the person was on before Support, so support knows
 * where the problem is. Route patterns only (see chatScreen).
 */
let cameFrom: string | null = null;

export function rememberScreen(routeId: string | null | undefined): void {
	if (!routeId || routeId.startsWith('/app/support')) return;
	cameFrom = chatScreen(routeId);
}

/** Slice 34: the last error the app showed: code, request ID, screen, time. */
export interface LastError {
	readonly code: string;
	readonly requestId: string | null;
	readonly screen: string;
	readonly at: string;
}

let lastError: LastError | null = null;

/** A PIN owed is the lock screen, not a problem worth reporting. */
const NOT_ERRORS = new Set(['pin_required']);

/**
 * Remembers the last refused or failed reply in this tab (never its body).
 * `routeId` reads the current route pattern; returns the stop function.
 */
export function watchErrors(routeId: () => string | null | undefined): () => void {
	const note = (code: string, requestId: string | null, background: boolean) => {
		// A background poll (the bell) failing is not what the person saw.
		if (background || NOT_ERRORS.has(code)) return;
		lastError = { code, requestId, screen: chatScreen(routeId()), at: new Date().toISOString() };
	};
	return observeReplies({
		replied: () => {},
		refused: note,
		failed: (reason, background) => note(reason, null, background)
	});
}

/** The parts of the browser deviceContext reads (a seam for tests). */
export interface DeviceInfo {
	readonly userAgent: string;
	readonly maxTouchPoints: number;
	readonly standalone: boolean;
	readonly language: string;
	readonly timeZone: string;
}

/** "Phone · Android 14 · Chrome 141" from the user agent; best effort. */
export function describeDevice(userAgent: string, maxTouchPoints: number): string {
	const ua = userAgent;
	const ipadOs = /Macintosh/.test(ua) && maxTouchPoints > 1;
	const major = (pattern: RegExp) => {
		const found = ua.match(pattern)?.[1];
		return found ? ` ${found}` : '';
	};
	const os =
		/iPhone|iPad|iPod/.test(ua) || ipadOs
			? `iOS${major(/OS (\d+)_/)}`
			: /Android/.test(ua)
				? `Android${major(/Android (\d+)/)}`
				: /CrOS/.test(ua)
					? 'ChromeOS'
					: /Windows/.test(ua)
						? 'Windows'
						: /Macintosh|Mac OS X/.test(ua)
							? 'macOS'
							: /Linux/.test(ua)
								? 'Linux'
								: 'Unknown OS';
	const browsers: [string, RegExp][] = [
		['Edge', /Edg(?:A|iOS)?\/(\d+)/],
		['Opera', /OPR\/(\d+)/],
		['Samsung Internet', /SamsungBrowser\/(\d+)/],
		['Firefox', /(?:Firefox|FxiOS)\/(\d+)/],
		['Chrome', /(?:Chrome|CriOS)\/(\d+)/],
		['Safari', /Version\/(\d+).*Safari/]
	];
	const found = browsers.find(([, pattern]) => pattern.test(ua));
	const browser = found ? `${found[0]}${major(found[1])}` : 'Unknown browser';
	const kind =
		/iPad|Tablet/.test(ua) || ipadOs || (/Android/.test(ua) && !/Mobile/.test(ua))
			? 'Tablet'
			: /Mobi|iPhone|iPod/.test(ua)
				? 'Phone'
				: 'Desktop';
	return `${kind} · ${os} · ${browser}`;
}

/** Everything this browser adds to the Chatwoot contact. */
export function browserContext(
	device: DeviceInfo,
	appVersion: string,
	screen: string,
	error: LastError | null
): ChatAttributes {
	const attributes: ChatAttributes = {
		screen,
		device: describeDevice(device.userAgent, device.maxTouchPoints),
		installed_app: device.standalone,
		app_version: appVersion,
		language: device.language,
		timezone: device.timeZone
	};
	if (error) {
		attributes.last_error = `${error.code} on ${error.screen}`;
		attributes.last_error_request = error.requestId ?? 'none';
		attributes.last_error_at = error.at;
	}
	return attributes;
}

function readDevice(): DeviceInfo {
	const nav = navigator as Navigator & { standalone?: boolean };
	return {
		userAgent: nav.userAgent.slice(0, 400),
		maxTouchPoints: nav.maxTouchPoints ?? 0,
		standalone: window.matchMedia('(display-mode: standalone)').matches || nav.standalone === true,
		language: nav.language ?? '',
		timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone ?? ''
	};
}

/**
 * Start a chat: read the chat settings, load Chatwoot once, identify the
 * person and open the panel. `screen` is used when the person came straight
 * to Support. False means chat is not available (unconfigured, offline,
 * blocked or failed); the caller says so honestly.
 */
export async function openSupportChat(screen: string, appVersion: string): Promise<boolean> {
	const exit = await Effect.runPromiseExit(getJson('/api/support/chat', SupportChat));
	if (!Exit.isSuccess(exit) || !exit.value.available) return false;
	const chat = exit.value;
	const ready = await loadWidget(chat);
	const api = window.$chatwoot;
	if (!ready || !api) return false;
	const attributes = {
		...chat.context,
		network: chat.network,
		...browserContext(readDevice(), appVersion, cameFrom ?? screen, lastError)
	};
	return startChat(api, chat, attributes);
}

/**
 * Identifies the person (HMAC-signed UID, name and email) and opens the
 * panel. An identity call that Chatwoot refuses must not stop the panel
 * opening: the person can still write to support, just unidentified.
 */
export function startChat(
	api: ChatwootApi,
	chat: {
		identifier: string;
		identifierHash: string;
		name: string | null;
		email: string | null;
	},
	attributes: ChatAttributes
): boolean {
	try {
		api.setUser(chat.identifier, {
			name: chat.name || chat.identifier,
			...(chat.email ? { email: chat.email } : {}),
			identifier_hash: chat.identifierHash
		});
		api.setCustomAttributes({ ...attributes, uid: chat.identifier });
	} catch {
		// keep going: open the chat without the identity
	}
	try {
		api.toggle('open');
		return true;
	} catch {
		return false;
	}
}
