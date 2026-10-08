<!--
	Cloudflare Turnstile widget (Blueprint 10): managed mode, shown only when
	Cloudflare needs an interaction ("interaction-only"), so most people never
	see it. Rendered explicitly so it survives client-side navigation between
	auth pages. It adds the hidden `cf-turnstile-response` field to the form;
	the server action verifies it. Tokens are single-use: the form calls
	reset() after every submission. No site key → nothing renders and the
	server refuses (fail closed).
-->
<script lang="ts" module>
	interface TurnstileApi {
		render(element: HTMLElement, options: Record<string, unknown>): string;
		reset(widgetId: string): void;
		remove(widgetId: string): void;
	}

	declare global {
		interface Window {
			turnstile?: TurnstileApi;
		}
	}

	const SCRIPT_SRC = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
	let loading: Promise<TurnstileApi> | null = null;

	/** Loads Cloudflare's script once per page (allowed by the CSP's script-src). */
	function loadTurnstile(): Promise<TurnstileApi> {
		if (window.turnstile) return Promise.resolve(window.turnstile);
		loading ??= new Promise((resolve, reject) => {
			const script = document.createElement('script');
			script.src = SCRIPT_SRC;
			script.async = true;
			script.onload = () =>
				window.turnstile ? resolve(window.turnstile) : reject(new Error('turnstile'));
			script.onerror = () => {
				loading = null;
				reject(new Error('turnstile'));
			};
			document.head.append(script);
		});
		return loading;
	}
</script>

<script lang="ts">
	import { onMount } from 'svelte';

	let {
		siteKey,
		action,
		theme = 'auto'
	}: {
		siteKey: string | null;
		action: 'sign-in' | 'sign-up' | 'forgot-password';
		theme?: 'dark' | 'light' | 'auto';
	} = $props();

	let container: HTMLDivElement | undefined = $state();
	let widgetId: string | null = null;
	let api: TurnstileApi | null = null;
	let failed = $state(false);

	/** Fresh token after a submission (each token verifies once). */
	export function reset(): void {
		if (api && widgetId) api.reset(widgetId);
	}

	onMount(() => {
		if (!siteKey) return;
		let cancelled = false;
		loadTurnstile()
			.then((loaded) => {
				if (cancelled || !container) return;
				api = loaded;
				widgetId = loaded.render(container, {
					sitekey: siteKey,
					action,
					theme,
					appearance: 'interaction-only',
					size: 'flexible',
					'refresh-expired': 'auto',
					'error-callback': () => {
						failed = true;
					},
					callback: () => {
						failed = false;
					}
				});
			})
			.catch(() => {
				failed = true;
			});
		return () => {
			cancelled = true;
			if (api && widgetId) api.remove(widgetId);
		};
	});
</script>

{#if siteKey}
	<div class="turnstile" bind:this={container}></div>
	<noscript><p class="note">Turn on JavaScript to complete the security check.</p></noscript>
	{#if failed}
		<p class="note" role="status">The security check didn’t load. Reload the page and try again.</p>
	{/if}
{/if}

<style>
	.turnstile:empty {
		display: none;
	}

	.note {
		color: var(--auth-body);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}
</style>
