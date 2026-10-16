// Push notifications (Blueprint 42), the pure parts: where push can work, what
// the Profile switch shows, and the payload the service worker trusts. Pure,
// so the service worker and the unit tests share them.

import type { InstallDevice } from './install';
import { safePath } from './app-path';

/**
 * - `supported`: the browser can subscribe here.
 * - `ios-install-first`: iPhone/iPad Safari; Apple sends push only to an app
 *   added to the Home Screen (iOS 16.4+).
 * - `unsupported`: no Push API (an in-app browser, an old browser).
 */
export type PushSupport = 'supported' | 'ios-install-first' | 'unsupported';

export interface PushEnvironment {
	readonly device: InstallDevice;
	/** Opened from the home screen, dock or Start menu. */
	readonly standalone: boolean;
	readonly serviceWorker: boolean;
	readonly pushManager: boolean;
	readonly notification: boolean;
}

export function pushSupportFor(env: PushEnvironment): PushSupport {
	if (env.device === 'in-app') return 'unsupported';
	if (env.device === 'ios' && !env.standalone) return 'ios-install-first';
	return env.serviceWorker && env.pushManager && env.notification ? 'supported' : 'unsupported';
}

/** PN02/PN03: what this device's switch shows; `hidden` leaves the group out. */
export type SwitchState = 'on' | 'off' | 'blocked' | 'ios-install-first' | 'hidden';

export function switchStateFor(
	support: PushSupport,
	permission: NotificationPermission | null,
	serverOn: boolean,
	configured: boolean
): SwitchState {
	if (support === 'unsupported' || !configured) return 'hidden';
	if (support === 'ios-install-first') return 'ios-install-first';
	if (permission === 'denied') return 'blocked';
	return serverOn && permission === 'granted' ? 'on' : 'off';
}

/** "this phone" or "this computer" (Blueprint 42 PN02). */
export const deviceNoun = (device: InstallDevice): string =>
	device === 'desktop' || device === 'mac-safari' ? 'this computer' : 'this phone';

export interface PushNotice {
	readonly id: string;
	readonly title: string;
	readonly body: string;
	readonly path: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const text = (value: unknown, max: number) =>
	typeof value === 'string' && value.length > 0 && value.length <= max ? value : null;

/** The worker's `{ v: 1, id, title, body, path }`, or null for anything else. */
export function parsePushPayload(raw: unknown): PushNotice | null {
	if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null;
	const p = raw as Record<string, unknown>;
	const id = typeof p.id === 'string' && UUID.test(p.id) ? p.id : null;
	const title = text(p.title, 80);
	const body = text(p.body, 200);
	if (p.v !== 1 || !id || !title || !body) return null;
	return { id, title, body, path: safePath(typeof p.path === 'string' ? p.path : undefined) };
}

/** base64url (the VAPID key) → bytes for PushManager.subscribe. */
export function keyBytes(base64url: string): Uint8Array<ArrayBuffer> {
	const base64 = base64url.replace(/-/g, '+').replace(/_/g, '/');
	const binary = atob(base64 + '='.repeat((4 - (base64.length % 4)) % 4));
	const bytes = new Uint8Array(new ArrayBuffer(binary.length));
	for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
	return bytes;
}
