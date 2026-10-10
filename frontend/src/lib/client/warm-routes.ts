// Blueprint 23: download every screen's code once the shell is ready and the
// browser is idle, so no tap waits for a chunk (about 1.8 MB once; accepted by
// the owner 2026-10-11). The service worker keeps each hashed file it fetches
// (src/service-worker), so later cold starts have them too. Code only: no
// data is read here.

import type { RouteId } from '$app/types';

/** Every /app page, by route id (preloadCode loads code only; no load runs). */
export const APP_ROUTES = [
	'/app',
	'/app/access',
	'/app/access/presidents',
	'/app/account',
	'/app/account/devices',
	'/app/account/password',
	'/app/account/pin',
	'/app/activity',
	'/app/adjust',
	'/app/audit',
	'/app/billing',
	'/app/billing/payments/[id]',
	'/app/convert',
	'/app/evidence',
	'/app/income',
	'/app/invitations',
	'/app/members',
	'/app/members/[id]',
	'/app/more',
	'/app/notifications',
	'/app/offices',
	'/app/offices/[id]',
	'/app/payout-accounts',
	'/app/payout-accounts/add',
	'/app/queue',
	'/app/queue/returns',
	'/app/reports',
	'/app/reports/export',
	'/app/reversals',
	'/app/reviews',
	'/app/settings',
	'/app/settings/backups',
	'/app/settings/backups/restore',
	'/app/settings/details',
	'/app/split',
	'/app/split/move',
	'/app/statements',
	'/app/support',
	'/app/team',
	'/app/transfers',
	'/app/wallets',
	'/app/withdrawals',
	'/app/withdrawals/new',
	// The workspace picker (Switch workspace opens it in the app).
	'/(auth)/workspaces'
] as const satisfies readonly RouteId[];

interface IdleWindow {
	requestIdleCallback?: (callback: () => void, options?: { timeout: number }) => number;
	navigator: Navigator & { connection?: { saveData?: boolean } };
}

const idle = (win: IdleWindow) =>
	new Promise<void>((resolve) => {
		if (win.requestIdleCallback) win.requestIdleCallback(() => resolve(), { timeout: 2000 });
		else setTimeout(resolve, 200);
	});

let started = false;

/**
 * Preloads the code of every route, one per idle period. Once per page load;
 * skipped when the browser asks to save data. Failures are ignored (the tap
 * then loads the chunk as before).
 */
export async function warmRoutes(
	preload: (id: RouteId) => Promise<void>,
	win: IdleWindow = window as unknown as IdleWindow,
	routes: readonly RouteId[] = APP_ROUTES
): Promise<number> {
	if (started || win.navigator.connection?.saveData) return 0;
	started = true;
	let done = 0;
	for (const route of routes) {
		await idle(win);
		try {
			await preload(route);
			done += 1;
		} catch {
			// best-effort
		}
	}
	return done;
}

/** Test seam. */
export function resetWarmRoutes(): void {
	started = false;
}
