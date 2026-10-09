import { defineConfig, devices } from '@playwright/test';

// E2E runs against the LOCAL Supabase stack only (decision 49). Start it with
// scripts/e2e-local.sh, which also serves the Edge Functions and exports
// SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY for the app server below.
export default defineConfig({
	testDir: 'tests/e2e',
	testMatch: '**/*.e2e.ts',
	// Files run side by side; tests inside a file stay in order (each file is
	// `serial`). Every test makes its own network and people, and the shared
	// helpers act only on their own rows, so files don't affect each other.
	fullyParallel: false,
	workers: Number(process.env.E2E_WORKERS ?? (process.env.CI ? 2 : 3)),
	// Whole money flows take ~30 s on CI's 2-core runner, more with two files
	// side by side; each expect keeps its own short timeout.
	timeout: 90_000,
	retries: process.env.CI ? 1 : 0,
	reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : 'list',
	use: {
		baseURL: 'http://127.0.0.1:3000',
		trace: 'retain-on-failure',
		...devices['Desktop Chrome']
	},
	webServer: {
		command: 'pnpm run build && pnpm run preview',
		url: 'http://127.0.0.1:3000/sign-in',
		reuseExistingServer: false,
		timeout: 180_000,
		env: {
			SUPABASE_URL: process.env.SUPABASE_URL ?? '',
			SUPABASE_PUBLISHABLE_KEY: process.env.SUPABASE_PUBLISHABLE_KEY ?? '',
			// Cloudflare's documented always-pass Turnstile test keys (Blueprint 10).
			TURNSTILE_SITE_KEY: '1x00000000000000000000AA',
			TURNSTILE_SECRET_KEY: '1x0000000000000000000000000000000AA',
			TURNSTILE_HOSTNAMES: 'example.com',
			// The fake providers (scripts/e2e-local.sh) answer siteverify locally.
			TURNSTILE_SITEVERIFY_URL: 'http://127.0.0.1:54399/turnstile/v0/siteverify',
			// Blueprint 14: the sign-in place comes from x-e2e-city / x-e2e-country
			// (local only; refused unless SUPABASE_URL is a loopback address).
			E2E_GEO_HEADERS: '1'
		}
	}
});
