// Service worker (decisions 36/36a/40): precaches the build assets, the static
// files and the prerendered app shell so the installed app opens offline.
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

const CACHE = `ew-shell-${version}`;
const SHELL = '/app';
const OFFLINE = '/offline.html';

// Large auth backgrounds are only needed online.
const precache = [
	...immutable.map((f) => `/${f.path}`),
	...assets.map((f) => `/${f.path}`).filter((p) => !p.startsWith('/auth-bg/desktop')),
	...prerendered.map((f) => `/${f.path}`)
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

const isAppNavigation = (url: URL) => url.pathname === SHELL || url.pathname.startsWith(`${SHELL}/`);

self.addEventListener('fetch', (event) => {
	const request = event.request;
	if (request.method !== 'GET') return;
	const url = new URL(request.url);
	if (url.origin !== self.location.origin) return;
	if (url.pathname.startsWith('/api/')) return;

	if (precached.has(url.pathname) && request.mode !== 'navigate') {
		event.respondWith(
			caches.match(url.pathname).then((hit) => hit ?? fetch(request))
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
