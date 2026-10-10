import { defineConfig } from 'vitest/config';
import adapter from '@sveltejs/adapter-cloudflare';
import { sveltekit } from '@sveltejs/kit/vite';

export default defineConfig({
	plugins: [
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			adapter: adapter(),
			// Plan §5.9: nonce-based CSP on every server-rendered page. The
			// prerendered app shell gets the same policy from static/_headers.
			csp: {
				mode: 'auto',
				directives: {
					'default-src': ['self'],
					// Cloudflare Turnstile on the auth forms (Blueprint 10). Chatwoot
					// Cloud's support chat (Blueprint 17, W-21), loaded only on Start a chat.
					'script-src': ['self', 'https://challenges.cloudflare.com', 'https://app.chatwoot.com'],
					'frame-src': ['https://challenges.cloudflare.com', 'https://app.chatwoot.com'],
					'style-src': ['self', 'unsafe-inline'],
					// blob: shows the chosen profile photo or logo before upload.
					'img-src': ['self', 'data:', 'blob:', 'https://app.chatwoot.com'],
					'font-src': ['self'],
					'connect-src': ['self', 'https://app.chatwoot.com', 'wss://app.chatwoot.com'],
					'manifest-src': ['self'],
					'worker-src': ['self'],
					'frame-ancestors': ['none'],
					'form-action': ['self'],
					'base-uri': ['none'],
					'object-src': ['none']
				}
			},
			// Update prompt (decision 36a): check for a new deployed version every 5 minutes.
			version: { pollInterval: 5 * 60 * 1000 }
		})
	],
	test: {
		expect: { requireAssertions: true },
		projects: [
			{
				extends: './vite.config.ts',
				test: {
					name: 'unit',
					environment: 'node',
					include: ['src/**/*.{test,spec}.{js,ts}'],
					exclude: ['src/**/*.svelte.{test,spec}.{js,ts}']
				}
			}
		]
	}
});
