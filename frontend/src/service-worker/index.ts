// Service worker (decisions 36/36a/40): precaches the signed-in shell's build
// files, the static files and the prerendered app shell so the installed app
// opens offline. Blueprint 20 B8: other route chunks (Admin included) are not
// precached; a hashed /_app/immutable/ file is kept the first time it loads.
// Blueprint 23: once the shell is ready and the browser is idle, the app
// preloads every /app screen's code (#lib/client/warm-routes), so this runtime
// cache soon holds all of them; install stays small and quick. Each version
// has its own cache, and activating a new version deletes the older ones.
// The Admin site registers no service worker (src/routes/+layout.svelte).
//
// Blueprint 42: it shows push notifications (only the worker's own payload
// shape; the link must be an app path) and opens that path when tapped. The
// payload carries a title and amount only (owner Q2), never names or banks.
//
// It NEVER caches: /api/* (wallet data, which lives in the device cache under
// the 36a rules instead), server-rendered auth/onboarding pages, form-action
// responses, Auth or Edge Function traffic, or anything cross-origin.

/// <reference no-default-lib="true"/>
/// <reference lib="esnext" />
/// <reference lib="webworker" />

import { self } from '$app/service-worker';
import { version } from '$app/env';
import { assets, immutable, prerendered } from '$app/manifest';
import { shellFiles } from 'virtual:ew-precache';
import { parsePushPayload } from '../lib/push';

const CACHE = `ew-shell-${version}`;
const SHELL = '/app';
const OFFLINE = '/offline.html';

// Large auth backgrounds and the gate-screen Root poses are only needed online;
// the shell keeps the poses it shows when it has nothing else to show offline
// (Blueprint 20 B8: other poses, e.g. home-empty, are kept once seen). Email
// images (static/email/) are for mail clients, never the app.
const SHELL_POSES = ['offline-empty', 'load-error'];
const neededOffline = (path: string) =>
	!path.startsWith('/auth-bg/desktop') &&
	// Slice 21: the sign-in pages' AVIF/WebP variants; the app's heroes use the JPEG.
	!/^\/auth-bg\/mobile-[a-z]+\.(avif|webp)$/.test(path) &&
	!path.startsWith('/email/') &&
	// Blueprint 35: iOS reads its launch images once, when the app is added.
	!path.startsWith('/splash/') &&
	(!path.startsWith('/root/') || SHELL_POSES.some((pose) => path.startsWith(`/root/${pose}`)));
// Blueprint 20 B8: the shell's chunks only (scripts/precache-plugin.ts); all of
// them if the list is missing.
const shell = shellFiles ? new Set(shellFiles) : null;
const precache = [
	...immutable.filter((f) => !shell || shell.has(f.path)).map((f) => `/${f.path}`),
	...assets.map((f) => `/${f.path}`).filter(neededOffline),
	// Offline, every /app/* navigation opens the /app shell: the other
	// prerendered pages are not needed.
	...prerendered.map((f) => `/${f.path}`).filter((p) => p.replace(/\/{2,}/g, '/') === SHELL)
].map((p) => p.replace(/\/{2,}/g, '/'));
const precached = new Set(precache);

self.addEventListener('install', (event) => {
	event.waitUntil(
		caches.open(CACHE).then(async (cache) => {
			await cache.addAll(precache);
			if (!precached.has(SHELL)) await cache.add(SHELL);
		})
	);
});

self.addEventListener('activate', (event) => {
	event.waitUntil(
		(async () => {
			for (const key of await caches.keys()) {
				if (key !== CACHE) await caches.delete(key);
			}
			await self.clients.claim();
		})()
	);
});

// The update prompt in the shell asks a waiting worker to take over.
self.addEventListener('message', (event) => {
	if (event.data?.type === 'SKIP_WAITING') void self.skipWaiting();
});

const isAppNavigation = (url: URL) =>
	url.pathname === SHELL || url.pathname.startsWith(`${SHELL}/`);

self.addEventListener('fetch', (event) => {
	const request = event.request;
	if (request.method !== 'GET') return;
	const url = new URL(request.url);
	if (url.origin !== self.location.origin) return;
	if (url.pathname.startsWith('/api/')) return;

	if (precached.has(url.pathname) && request.mode !== 'navigate') {
		event.respondWith(caches.match(url.pathname).then((hit) => hit ?? fetch(request)));
		return;
	}

	// Hashed build files never change, and Root poses are static: keep each one
	// the first time it loads, so a page opened online also opens offline
	// (code and images only, never data).
	if (url.pathname.startsWith('/_app/immutable/') || url.pathname.startsWith('/root/')) {
		event.respondWith(
			(async () => {
				const hit = await caches.match(url.pathname);
				if (hit) return hit;
				const response = await fetch(request);
				if (response.ok) {
					const cache = await caches.open(CACHE);
					await cache.put(url.pathname, response.clone());
				}
				return response;
			})()
		);
		return;
	}

	if (request.mode === 'navigate') {
		event.respondWith(
			(async () => {
				try {
					return await fetch(request);
				} catch {
					// Offline: the signed-in app opens from the precached shell;
					// every other page gets the static offline notice.
					const fallback = await caches.match(isAppNavigation(url) ? SHELL : OFFLINE);
					return fallback ?? Response.error();
				}
			})()
		);
	}
});

// ── Push (Blueprint 42) ─────────────────────────────────────────────────────

self.addEventListener('push', (event) => {
	let raw: unknown;
	try {
		raw = event.data?.json();
	} catch {
		return; // not JSON: not ours
	}
	const notice = parsePushPayload(raw);
	if (!notice) return;
	event.waitUntil(
		self.registration.showNotification(notice.title, {
			body: notice.body,
			// One notification per bell item: a retry replaces it.
			tag: notice.id,
			icon: '/icons/icon-192.png',
			badge: '/icons/badge-96.png',
			data: { path: notice.path }
		})
	);
});

self.addEventListener('notificationclick', (event) => {
	event.notification.close();
	const notice = parsePushPayload({
		v: 1,
		id: event.notification.tag,
		title: event.notification.title || 'Elivate Wallet',
		body: event.notification.body || ' ',
		path: (event.notification.data as { path?: unknown } | null)?.path
	});
	const target = new URL(notice?.path ?? SHELL, self.location.origin).href;
	event.waitUntil(
		(async () => {
			const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
			const open = windows.find((w) => new URL(w.url).origin === self.location.origin);
			if (open) {
				await open.focus();
				if (open.url !== target) await open.navigate(target).catch(() => null);
				return;
			}
			await self.clients.openWindow(target);
		})()
	);
});

// The push service replaced this browser's subscription: subscribe again with
// the same key. The app saves it for the signed-in session on its next start
// (resumePush), with this device's Hide amounts.
self.addEventListener('pushsubscriptionchange', (event) => {
	const change = event as Event & {
		readonly oldSubscription?: PushSubscription | null;
		waitUntil(promise: Promise<unknown>): void;
	};
	const key = change.oldSubscription?.options.applicationServerKey;
	if (!key) return;
	change.waitUntil(
		self.registration.pushManager
			.subscribe({ userVisibleOnly: true, applicationServerKey: key })
			.catch(() => null)
	);
});
