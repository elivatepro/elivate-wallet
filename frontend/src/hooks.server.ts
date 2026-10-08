import type { Handle, HandleServerError } from '@sveltejs/kit/hooks';
import { building } from '$app/env';
import { createAuthClient, verifiedSession, type VerifiedSession } from '#lib/server/auth.js';
import { requireConfig } from '#lib/server/config.js';
import { readTheme } from '#lib/server/cookies.js';

export const handle: Handle = async ({ event, resolve }) => {
	event.locals.theme = readTheme(event.cookies);
	event.locals.secureCookies = event.url.protocol === 'https:';

	let client: ReturnType<typeof createAuthClient> | null = null;
	event.locals.supabase = () => {
		if (!client) {
			const config = requireConfig();
			client = createAuthClient(event.cookies, {
				supabaseUrl: config.supabaseUrl,
				publishableKey: config.publishableKey,
				secureCookies: event.locals.secureCookies,
				fetch: event.fetch
			});
		}
		return client;
	};
	let session: Promise<VerifiedSession | null> | null = null;
	event.locals.session = () => {
		if (building) return Promise.resolve(null);
		session ??= verifiedSession(event.locals.supabase());
		return session;
	};

	const response = await resolve(event, {
		transformPageChunk: ({ html }) => html.replace('%ew.theme%', event.locals.theme),
		filterSerializedResponseHeaders: (name) => name === 'content-type'
	});

	// Plan §5.9: nothing the server renders or relays may be cached or leak a
	// referrer off-site. `same-origin`, not `no-referrer`: with `no-referrer`
	// browsers send `Origin: null` on form POSTs and Kit's CSRF check refuses them.
	if (!building) {
		response.headers.set('cache-control', 'no-store');
		response.headers.set('referrer-policy', 'same-origin');
		response.headers.set('x-content-type-options', 'nosniff');
		response.headers.set('permissions-policy', 'camera=(), microphone=(), geolocation=()');
	}
	return response;
};

// Logs carry only the route pattern and a generated id (plan §5.9): no user,
// session, membership, email, IP, token or request body. Unknown errors never
// reach the page with their real message.
export const handleError: HandleServerError = ({ kind, event }) => {
	if (kind !== 'unknown') return;
	const id = crypto.randomUUID();
	console.error(JSON.stringify({ id, route: event.route.id ?? 'unknown', status: 500 }));
	return { message: 'Something went wrong. Try again.' };
};
