// Push notifications in the browser (Blueprint 42): this device's switch.
// The browser keeps its subscription; the backend ties it to the signed-in
// session, so signing out ends push there. Signing in again as the same person
// turns it back on by itself (resumePush); someone else starts with it off.

import { Effect } from 'effect';
import { COMMAND_TIMEOUT_MS, READ_TIMEOUT_MS, requestJson } from '#lib/contract/transport.js';
import { PUSH_PATH, PushState, type PushState as PushStateType } from '#lib/contract/push.js';
import { installDeviceFor } from '#lib/install.js';
import { keyBytes, pushSupportFor, type PushSupport } from '#lib/push.js';
import { runningInstalled } from './install-prompt.svelte';

/** Whose push this browser's subscription is (a UID); cleared when turned off. */
const OWNER_KEY = 'ew_push_owner';
/** Same key as the shell's Hide amounts (Blueprint 41). */
const HIDE_AMOUNTS_KEY = 'ew:pref:hide-amounts';

export function pushSupport(): PushSupport {
	return pushSupportFor({
		device: installDeviceFor(navigator.userAgent, navigator.maxTouchPoints),
		standalone: runningInstalled(),
		serviceWorker: 'serviceWorker' in navigator,
		pushManager: 'PushManager' in window,
		notification: 'Notification' in window
	});
}

export const permission = (): NotificationPermission | null =>
	'Notification' in window ? Notification.permission : null;

export function storedHideAmounts(): boolean {
	try {
		return localStorage.getItem(HIDE_AMOUNTS_KEY) === '1';
	} catch {
		return false;
	}
}

function owner(): string | null {
	try {
		return localStorage.getItem(OWNER_KEY);
	} catch {
		return null;
	}
}

function setOwner(uid: string | null): void {
	try {
		if (uid) localStorage.setItem(OWNER_KEY, uid);
		else localStorage.removeItem(OWNER_KEY);
	} catch {
		// best-effort: without it, push isn't turned back on by itself
	}
}

/** The service worker's registration, if it is up within a few seconds. */
async function registration(): Promise<ServiceWorkerRegistration | null> {
	if (!('serviceWorker' in navigator)) return null;
	return Promise.race([
		navigator.serviceWorker.ready,
		new Promise<null>((resolve) => setTimeout(() => resolve(null), 8000))
	]);
}

async function subscription(): Promise<PushSubscription | null> {
	const reg = await registration();
	return reg ? reg.pushManager.getSubscription() : null;
}

const run = <A>(effect: Effect.Effect<A, unknown>) => Effect.runPromise(effect);

function read(endpoint: string | null): Promise<PushStateType> {
	const query = endpoint ? `?endpoint=${encodeURIComponent(endpoint)}` : '';
	return run(
		requestJson(
			{
				fetch,
				url: `${PUSH_PATH}${query}`,
				method: 'GET',
				route: `GET ${PUSH_PATH}`,
				timeoutMs: READ_TIMEOUT_MS,
				background: true
			},
			PushState
		)
	);
}

function save(sub: PushSubscription, hideAmounts: boolean): Promise<PushStateType> {
	const json = sub.toJSON();
	return run(
		requestJson(
			{
				fetch,
				url: PUSH_PATH,
				method: 'PUT',
				route: `PUT ${PUSH_PATH}`,
				body: {
					endpoint: sub.endpoint,
					keys: { p256dh: json.keys?.p256dh ?? '', auth: json.keys?.auth ?? '' },
					hideAmounts
				},
				timeoutMs: COMMAND_TIMEOUT_MS
			},
			PushState
		)
	);
}

export interface DevicePush {
	readonly on: boolean;
	/** The backend has a VAPID key (push is set up). */
	readonly configured: boolean;
}

/**
 * Every subscription write (on, off, Hide amounts, re-sync) runs in order, so
 * an older save never undoes a newer choice or brings back a deleted one.
 */
let writes: Promise<unknown> = Promise.resolve();

function inOrder<A>(task: () => Promise<A>): Promise<A> {
	const next = writes.then(task, task);
	writes = next.catch(() => undefined);
	return next;
}

/** What the backend says about this browser's subscription (after pending writes). */
export async function readDevicePush(): Promise<DevicePush> {
	await writes;
	const sub = await subscription();
	const state = await read(sub?.endpoint ?? null);
	return { on: state.on, configured: state.publicKey !== null };
}

/** Same key the subscription was made with (a key change needs a new one). */
function sameKey(sub: PushSubscription, key: Uint8Array): boolean {
	const current = sub.options.applicationServerKey;
	if (!current) return false;
	const bytes = new Uint8Array(current);
	return bytes.length === key.length && bytes.every((b, i) => b === key[i]);
}

export type EnableResult = 'on' | 'blocked' | 'off' | 'unavailable';

/**
 * Asks the browser's permission (call straight from the tap), subscribes and
 * saves the subscription for this session.
 */
export async function enablePush(
	uid: string,
	hideAmounts = storedHideAmounts()
): Promise<EnableResult> {
	if (!('Notification' in window)) return 'unavailable';
	const answer =
		Notification.permission === 'default'
			? await Notification.requestPermission()
			: Notification.permission;
	if (answer === 'denied') return 'blocked';
	if (answer !== 'granted') return 'off';
	return inOrder(async () => {
		const reg = await registration();
		if (!reg) return 'unavailable';
		const { publicKey } = await read(null);
		if (!publicKey) return 'unavailable';
		const key = keyBytes(publicKey);
		let sub = await reg.pushManager.getSubscription();
		if (sub && !sameKey(sub, key)) {
			await sub.unsubscribe();
			sub = null;
		}
		sub ??= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
		const state = await save(sub, hideAmounts);
		setOwner(uid);
		return state.on ? 'on' : 'off';
	});
}

/**
 * Turns push off for this device: the backend first, then the browser. The
 * owner mark stays until the backend confirms, so a failed "off" still lets
 * Hide amounts reach the device.
 */
export function disablePush(): Promise<void> {
	return inOrder(async () => {
		const sub = await subscription();
		if (!sub) return setOwner(null);
		await run(
			requestJson(
				{
					fetch,
					url: PUSH_PATH,
					method: 'DELETE',
					route: `DELETE ${PUSH_PATH}`,
					body: { endpoint: sub.endpoint },
					timeoutMs: COMMAND_TIMEOUT_MS
				},
				PushState
			)
		);
		setOwner(null);
		await sub.unsubscribe().catch(() => false);
	});
}

/** This browser's push belongs to `uid` and is still allowed. */
async function ownSubscription(uid: string): Promise<PushSubscription | null> {
	if (permission() !== 'granted' || owner() !== uid) return null;
	return subscription();
}

/**
 * After sign-in (the shell is ready): the same person on the same device gets
 * push back by itself. Quiet: a failure waits for the next start.
 */
export function resumePush(uid: string, hideAmounts: boolean): Promise<void> {
	return inOrder(async () => {
		try {
			const sub = await ownSubscription(uid);
			if (sub) await save(sub, hideAmounts);
		} catch {
			// quiet
		}
	});
}

/** The Hide amounts switch changed: notifications follow it. */
export const syncHideAmounts = resumePush;
