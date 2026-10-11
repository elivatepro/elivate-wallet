import { readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import { APP_ROUTES, resetWarmRoutes, warmRoutes } from './warm-routes';

/** Every +page.svelte under src/routes/app, as a route id. */
function appPages(dir = 'src/routes/app', base = '/app'): string[] {
	const out: string[] = [];
	for (const name of readdirSync(dir)) {
		const full = join(dir, name);
		if (statSync(full).isDirectory()) {
			if (name.startsWith('[...')) continue; // the not-found catch-all
			out.push(...appPages(full, `${base}/${name}`));
		} else if (name === '+page.svelte') out.push(base);
	}
	return out;
}

const win = (saveData = false) => ({
	requestIdleCallback: (callback: () => void) => {
		queueMicrotask(callback);
		return 0;
	},
	navigator: { connection: { saveData } } as unknown as Navigator & {
		connection?: { saveData?: boolean };
	}
});

beforeEach(() => resetWarmRoutes());

describe('warmRoutes (Blueprint 23)', () => {
	it('lists every /app page', () => {
		expect([...APP_ROUTES].filter((r) => r.startsWith('/app')).sort()).toEqual(appPages().sort());
	});

	it('preloads each route once per page load', async () => {
		const seen: string[] = [];
		const preload = async (id: string) => void seen.push(id);
		expect(await warmRoutes(preload, win(), ['/app', '/app/more'])).toBe(2);
		expect(await warmRoutes(preload, win(), ['/app'])).toBe(0);
		expect(seen).toEqual(['/app', '/app/more']);
	});

	it('skips when the browser asks to save data, and ignores failures', async () => {
		expect(await warmRoutes(async () => undefined, win(true), ['/app'])).toBe(0);
		resetWarmRoutes();
		const failing = async (id: string) => {
			if (id === '/app') throw new Error('offline');
		};
		expect(await warmRoutes(failing, win(), ['/app', '/app/more'])).toBe(1);
	});
});
