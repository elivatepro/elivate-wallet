import { defineConfig, devices } from '@playwright/test';

// E2E runs against the LOCAL Supabase stack only (decision 49). Start it with
// scripts/e2e-local.sh, which also serves the Edge Functions and exports
// SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY for the app server below.
export default defineConfig({
	testDir: 'tests/e2e',
	testMatch: '**/*.e2e.ts',
	fullyParallel: false,
	workers: 1,
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
			SUPABASE_PUBLISHABLE_KEY: process.env.SUPABASE_PUBLISHABLE_KEY ?? ''
		}
	}
});
