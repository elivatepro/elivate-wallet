import type { Handle, HandleServerError } from '@sveltejs/kit/hooks';
import { error, redirect } from '@sveltejs/kit';
import { building } from '$app/env';
import { createAuthClient, verifiedSession, type VerifiedSession } from '#lib/server/auth.js';
import { requireConfig, surfaceFor } from '#lib/server/config.js';
import { readTheme } from '#lib/server/cookies.js';

/** Paths both sites serve (theme switch, version poll for the update prompt). */
const SHARED_PATHS = ['/theme', '/_app/'];

export const handle: Handle = async ({ event, resolve }) => {
	event.locals.theme = readTheme(event.cookies);
	event.locals.secureCookies = event.url.protocol === 'https:';

	// Blueprint 18: one codebase, two Workers. The admin site serves only
	// /admin/*; the Wallet app never serves /admin/*.
	const path = event.url.pathname;
	const surface = building ? 'member' : surfaceFor(path);
	event.locals.surface = surface;
	const isAdminPath = path === '/admin' || path.startsWith('/admin/');
	if (!building && !SHARED_PATHS.some((p) => path.startsWith(p))) {
		if (surface === 'admin' && !isAdminPath) {
			if (path === '/') redirect(303, '/admin');
			error(404, 'Not found');
		}
		if (surface === 'member' && isAdminPath) error(404, 'Not found');
	}

	let client: ReturnType<typeof createAuthClient> | null = null;
	event.locals.supabase = () => {
		if (!client) {
			const config = requireConfig();
			client = createAuthClient(event.cookies, {
				supabaseUrl: config.supabaseUrl,
				publishableKey: config.publishableKey,
				secureCookies: event.locals.secureCookies,
				fetch: event.fetch,
				userAgent: event.request.headers.get('user-agent'),
				surface
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
	// A route that chose its own cache policy keeps it (the brand logo and the
	// own profile photo: private, versioned URLs); everything else is no-store.
	if (!building) {
		if (!response.headers.has('cache-control')) response.headers.set('cache-control', 'no-store');
		response.headers.set('referrer-policy', 'same-origin');
		response.headers.set('x-content-type-options', 'nosniff');
		response.headers.set('permissions-policy', 'camera=(), microphone=(), geolocation=()');
		if (surface === 'admin') {
			response.headers.set('x-robots-tag', 'noindex, nofollow');
			response.headers.set('x-frame-options', 'DENY');
		}
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
