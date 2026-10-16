// The bell's link allow-list (Blueprint 13), on its own so the service worker
// can use it for push (Blueprint 42) without the bell's wording.

const PATH =
	/^\/app(\/[a-z][a-z-]*)*(\?withdrawal=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$|^\/app\/billing\/payments\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** The item's in-app link, or Home when it is missing or not an app path. */
export function safePath(path: string | undefined): string {
	return path && PATH.test(path) ? path : '/app';
}
