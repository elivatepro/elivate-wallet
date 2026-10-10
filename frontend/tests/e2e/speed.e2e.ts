// Blueprint 23 B0: tap → first meaningful paint, measured on a throttled
// mobile profile against the local stack (synthetic data only). Not a pass/fail
// test: it runs only with E2E_SPEED=1 and writes its numbers to E2E_SPEED_OUT
// (JSON). Usage:
//   E2E_SPEED=1 E2E_SPEED_OUT=/tmp/speed.json scripts/e2e-local.sh speed.e2e.ts
//
// For each run: a new browser context (no device cache, service worker
// blocked so every fetch is throttled) signs in as a President, turns on
// throttling (150 ms RTT, 1.6 Mbps down, CPU ×4, +300 ms per /api read for the
// trip to Supabase), reloads Home and stays idle 12 s, then taps each route
// from the More page twice: "cold" (first visit) and "warm" (revisit). Times are taken
// in the page: `nav` until the URL changed, `paint` until the route's data
// marker is on screen, `feedback` until the tapped tab shows as current.

import { writeFileSync } from 'node:fs';
import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import { createConfirmedAccount, recordIncome, uniqueEmail, walletPeople } from './helpers';

const { PASSWORD, PIN, memberWithAccount, asPresident } = walletPeople;
const NETWORK = 'Speed Test Network';
const RUNS = Number(process.env.E2E_SPEED_RUNS ?? 3);
const API_MS = Number(process.env.E2E_SPEED_API_MS ?? 300);

test.skip(!process.env.E2E_SPEED, 'speed probe: set E2E_SPEED=1');
test.describe.configure({ mode: 'serial' });
test.use({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
test.setTimeout(600_000);

const founder = { email: uniqueEmail('speed-f'), password: PASSWORD, pin: PIN };
const member = uniqueEmail('speed-m');

/** Route, and a pattern that only matches once its data is on screen. */
const ROUTES: readonly (readonly [string, string])[] = [
	['/app/team', '₦1,000\\.00'],
	['/app/members', 'Ada Obi'],
	['/app/offices', '₦1,000\\.00'],
	['/app/audit', '\\d+\\+? events?'],
	['/app/invitations', member.replace(/[.+]/g, '\\$&')]
];

interface Tap {
	readonly route: string;
	readonly nav: number;
	readonly paint: number;
}

/** Clicks the visible link to `href` and times the swap and the data in the page. */
async function tap(page: Page, href: string, marker: string): Promise<Tap> {
	const result = await page.evaluate(
		async ({ href, marker }) => {
			const link = [...document.querySelectorAll<HTMLAnchorElement>(`a[href="${href}"]`)].find(
				(a) => a.offsetParent !== null
			);
			if (!link) throw new Error(`no visible link to ${href}`);
			const t0 = performance.now();
			link.click();
			let nav = -1;
			return await new Promise<{ nav: number; paint: number }>((resolve, reject) => {
				const stop = setTimeout(() => reject(new Error(`timeout on ${href}`)), 30_000);
				const tick = () => {
					const now = performance.now() - t0;
					if (nav < 0 && location.pathname === href) nav = now;
					const main = document.querySelector('main');
					if (nav >= 0 && main && new RegExp(marker).test(main.innerText)) {
						clearTimeout(stop);
						resolve({ nav, paint: now });
						return;
					}
					requestAnimationFrame(tick);
				};
				tick();
			});
		},
		{ href, marker }
	);
	return { route: href, ...result };
}

/** Taps a tab-bar tab and times until it shows as the current page. */
async function tabFeedback(page: Page, href: string): Promise<number> {
	return page.evaluate(async (href) => {
		const tab = document.querySelector<HTMLAnchorElement>(`.tabbar a[href="${href}"]`);
		if (!tab) throw new Error(`no tab ${href}`);
		const t0 = performance.now();
		tab.click();
		return await new Promise<number>((resolve) => {
			const tick = () => {
				if (tab.getAttribute('aria-current') === 'page') resolve(performance.now() - t0);
				else requestAnimationFrame(tick);
			};
			tick();
		});
	}, href);
}

async function toMore(page: Page) {
	if (new URL(page.url()).pathname !== '/app/more') {
		await tabFeedback(page, '/app/more');
		await expect(page).toHaveURL(/\/app\/more$/);
	}
	await expect(page.locator('main a[href="/app/members"]')).toBeVisible();
}

test('tap speed (Blueprint 23 B0)', async ({ browser }) => {
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, NETWORK, member);
	await recordIncome(founder, member, '1000.00');

	const runs: { cold: Tap[]; warm: Tap[]; tabs: number[] }[] = [];
	for (let run = 0; run < RUNS; run += 1) {
		// No service worker: its fetches would skip the page's throttling.
		const context = await browser.newContext({
			viewport: { width: 390, height: 844 },
			isMobile: true,
			hasTouch: true,
			serviceWorkers: 'block'
		});
		const page = await context.newPage();
		await asPresident(page, founder.email, NETWORK);
		await expect(page).toHaveURL(/\/app$/);

		// The local stack answers in a few ms; the Worker → Supabase (London)
		// round trip from Lagos is added to every /api read.
		await context.route('**/api/**', async (route) => {
			await new Promise((resolve) => setTimeout(resolve, API_MS));
			await route.continue();
		});
		const cdp = await context.newCDPSession(page);
		await cdp.send('Network.enable');
		await cdp.send('Network.emulateNetworkConditions', {
			offline: false,
			latency: 150,
			downloadThroughput: (1.6 * 1024 * 1024) / 8,
			uploadThroughput: (750 * 1024) / 8
		});
		await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
		// Idle on Home (time for the new build to fetch every screen's code).
		await page.reload();
		await page.waitForTimeout(12_000);

		const cold: Tap[] = [];
		const warm: Tap[] = [];
		const tabs: number[] = [];
		for (const pass of [cold, warm]) {
			for (const [route, marker] of ROUTES) {
				await toMore(page);
				pass.push(await tap(page, route, marker));
				await page.waitForTimeout(300);
			}
		}
		for (const href of ['/app', '/app/team', '/app/more']) {
			tabs.push(await tabFeedback(page, href));
			await page.waitForTimeout(1500);
		}
		runs.push({ cold, warm, tabs });
		await context.close();
	}

	const out = process.env.E2E_SPEED_OUT;
	if (out) {
		const routes = ROUTES.map(([r]) => r);
		writeFileSync(out, JSON.stringify({ routes, apiMs: API_MS, runs }, null, 2));
	}
	expect(runs).toHaveLength(RUNS);
});
