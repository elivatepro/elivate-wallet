// Blueprint 20 B0: timing probe for the signed-in app (not shipped).
//
// Signs the synthetic PERF_TEST_* account in through Supabase Auth with the
// same @supabase/ssr cookies the BFF writes (Auth itself has no captcha; the
// Worker's Turnstile step guards only its own sign-in form), proves the PIN in
// a real browser, then times app opens and the /api reads. Prints Markdown.
// Signs out at the end. Never prints a credential, token or response body.
//
// Usage (from frontend/, values from the repo-root .env):
//   node --env-file=../.env scripts/perf-probe.ts > ../docs/perf/<date>-baseline.md
// Env: PERF_TEST_EMAIL, PERF_TEST_PASSWORD, PERF_TEST_PIN, PERF_SUPABASE_URL,
//   PERF_PUBLISHABLE_KEY, PERF_BASE (default https://app.elivatewallet.com),
//   PERF_RUNS (default 5).

import { createServerClient } from '@supabase/ssr';
import { chromium, type BrowserContext, type Page } from '@playwright/test';

const env = (name: string, fallback?: string) => {
	const value = process.env[name] ?? fallback;
	if (!value) throw new Error(`missing ${name}`);
	return value;
};
const BASE = env('PERF_BASE', 'https://app.elivatewallet.com');
const RUNS = Number(env('PERF_RUNS', '5'));
const host = new URL(BASE).hostname;

type Cookie = { name: string; value: string };

async function signIn(): Promise<Cookie[]> {
	const jar = new Map<string, string>();
	const supabase = createServerClient(env('PERF_SUPABASE_URL'), env('PERF_PUBLISHABLE_KEY'), {
		cookieOptions: { name: 'ew-auth' },
		cookies: {
			getAll: () => [...jar].map(([name, value]) => ({ name, value })),
			setAll: (toSet) => toSet.forEach(({ name, value }) => jar.set(name, value))
		},
		auth: { autoRefreshToken: false, detectSessionInUrl: false }
	});
	const { error } = await supabase.auth.signInWithPassword({
		email: env('PERF_TEST_EMAIL'),
		password: env('PERF_TEST_PASSWORD')
	});
	if (error) throw new Error(`sign-in failed: ${error.code ?? error.status}`);
	return [...jar].map(([name, value]) => ({ name, value }));
}

async function provePin(page: Page) {
	await page.goto(`${BASE}/pin`);
	await page.locator('input[name="pin"]').fill(env('PERF_TEST_PIN'));
	await page.getByRole('button', { name: 'Verify' }).click();
	await page.waitForURL((url) => !url.pathname.startsWith('/pin'), { timeout: 30_000 });
	if (new URL(page.url()).pathname.startsWith('/workspaces')) {
		await page.locator('form[action="?/select"] button:not([disabled])').first().click();
		await page.waitForURL((url) => url.pathname.startsWith('/app'), { timeout: 30_000 });
	}
}

interface ApiTiming {
	path: string;
	start: number;
	ms: number;
	status: number;
}

/** Opens a path and records every same-origin /api call until the network is idle. */
async function timeOpen(page: Page, path: string) {
	const calls: ApiTiming[] = [];
	let t0 = 0;
	const onFinished = async (req: import('@playwright/test').Request) => {
		const url = new URL(req.url());
		if (url.hostname !== host || !url.pathname.startsWith('/api/')) return;
		const t = req.timing();
		const res = await req.response();
		calls.push({
			path: url.pathname,
			start: t.startTime - t0,
			ms: t.responseEnd,
			status: res?.status() ?? 0
		});
	};
	page.on('requestfinished', onFinished);
	t0 = Date.now();
	await page.goto(`${BASE}${path}`, { waitUntil: 'networkidle' });
	const total = Date.now() - t0;
	page.off('requestfinished', onFinished);
	const lastApi = calls.reduce((max, c) => Math.max(max, c.start + c.ms), 0);
	return { total, lastApi: Math.round(lastApi), calls };
}

const median = (xs: number[]) => {
	const s = [...xs].sort((a, b) => a - b);
	return Math.round(s[Math.floor(s.length / 2)] ?? 0);
};
const p90 = (xs: number[]) => {
	const s = [...xs].sort((a, b) => a - b);
	return Math.round(s[Math.min(s.length - 1, Math.floor(s.length * 0.9))] ?? 0);
};

async function freshContext(browser: import('@playwright/test').Browser, cookies: Cookie[]) {
	const context = await browser.newContext({ serviceWorkers: 'block' });
	await context.addCookies(
		cookies.map((c) => ({ ...c, domain: host, path: '/', secure: true, httpOnly: true }))
	);
	return context;
}

async function main() {
	const cookies = await signIn();
	const browser = await chromium.launch();
	const setup = await freshContext(browser, cookies);
	const setupPage = await setup.newPage();
	await provePin(setupPage);
	// The PIN proof and workspace now live on the server and in ew_ws.
	const all = (await setup.cookies()).map(({ name, value }) => ({ name, value }));
	await setup.close();

	const lines: string[] = [];
	const out = (s = '') => lines.push(s);
	out(`# Perf probe ${new Date().toISOString()}`);
	out();
	out(`Base ${BASE}; ${RUNS} runs each; service worker blocked (cold = new browser context).`);
	out();

	const scenarios = ['/app', '/app/activity', '/app/wallets', '/app/settings'];
	out('## Page opens (cold context)');
	out();
	out(
		'| Path | Network idle median / p90 (ms) | Last /api done median (ms) | /api calls (in start order) |'
	);
	out('|---|---|---|---|');
	for (const path of scenarios) {
		const totals: number[] = [];
		const lasts: number[] = [];
		let shape = '';
		for (let i = 0; i < RUNS; i++) {
			const context: BrowserContext = await freshContext(browser, all);
			const page = await context.newPage();
			const r = await timeOpen(page, path);
			totals.push(r.total);
			lasts.push(r.lastApi);
			shape = r.calls
				.sort((a, b) => a.start - b.start)
				.map(
					(c) =>
						`${c.path} ${Math.round(c.ms)}ms@${Math.round(c.start)}${c.status === 200 ? '' : ` (${c.status})`}`
				)
				.join(', ');
			await context.close();
		}
		out(`| ${path} | ${median(totals)} / ${p90(totals)} | ${median(lasts)} | ${shape} |`);
	}
	out();

	const cookieHeader = all.map((c) => `${c.name}=${c.value}`).join('; ');
	const endpoints = ['/api/session', '/api/home', '/api/activity', '/api/wallets', '/api/settings'];
	out('## Endpoint latency (Node fetch, sequential)');
	out();
	out('| Endpoint | Status | Median (ms) | p90 (ms) |');
	out('|---|---|---|---|');
	for (const path of endpoints) {
		const times: number[] = [];
		let status = 0;
		for (let i = 0; i < RUNS * 2; i++) {
			const t = performance.now();
			const res = await fetch(`${BASE}${path}`, { headers: { cookie: cookieHeader } });
			await res.arrayBuffer();
			times.push(performance.now() - t);
			status = res.status;
		}
		out(`| ${path} | ${status} | ${median(times)} | ${p90(times)} |`);
	}
	out();

	// Sign out so the probe leaves no live session behind.
	const signOut = await browser.newContext();
	await signOut.addCookies(all.map((c) => ({ ...c, domain: host, path: '/', secure: true })));
	await signOut.request.post(`${BASE}/sign-out`, { headers: { origin: BASE }, form: {} });
	await signOut.close();
	await browser.close();
	console.log(lines.join('\n'));
}

main().catch((e) => {
	console.error(e instanceof Error ? e.message : 'probe failed');
	process.exit(1);
});
