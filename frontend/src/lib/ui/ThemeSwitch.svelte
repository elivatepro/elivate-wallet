<!--
	Dark / Light / System (W-01). A plain POST form so it works before JavaScript;
	desktop shows the segmented control from Paper, mobile the single round button
	that steps to the next theme.
-->
<script lang="ts">
	import { page } from '$app/state';
	import Moon from '@lucide/svelte/icons/moon';
	import Sun from '@lucide/svelte/icons/sun';
	import SunMoon from '@lucide/svelte/icons/sun-moon';
	import type { Theme } from '#lib/theme.js';

	let { theme }: { theme: Theme } = $props();

	const labels: Record<Theme, string> = { dark: 'Dark', light: 'Light', system: 'System' };
	const order: Theme[] = ['dark', 'light', 'system'];
	const nextTheme = $derived(order[(order.indexOf(theme) + 1) % order.length] ?? 'dark');
	// Keep the query: /auth/confirm needs its token_hash and type after a theme change.
	const next = $derived(page.url.pathname + page.url.search);
</script>

<form method="POST" action="/theme" class="theme">
	<input type="hidden" name="next" value={next} />
	<div class="segmented" role="group" aria-label="Theme">
		{#each order as option (option)}
			<button
				type="submit"
				name="theme"
				value={option}
				class:active={option === theme}
				aria-pressed={option === theme}>{labels[option].toUpperCase()}</button
			>
		{/each}
	</div>
	<button
		type="submit"
		name="theme"
		value={nextTheme}
		class="round"
		aria-label={`Theme: ${labels[theme]}. Switch to ${labels[nextTheme]}`}
	>
		{#if theme === 'dark'}
			<Moon size={18} strokeWidth={1.6} aria-hidden="true" />
		{:else if theme === 'light'}
			<Sun size={18} strokeWidth={1.6} aria-hidden="true" />
		{:else}
			<SunMoon size={18} strokeWidth={1.6} aria-hidden="true" />
		{/if}
	</button>
</form>

<style>
	.theme {
		display: contents;
	}

	.segmented {
		display: none;
	}

	.round {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: var(--hit-min);
		height: var(--hit-min);
		border-radius: var(--radius-pill);
		border: 1px solid var(--auth-chip-border);
		background: var(--auth-chip-bg);
		color: var(--color-text);
		cursor: pointer;
	}

	@media (min-width: 1024px) {
		.round {
			display: none;
		}

		.segmented {
			display: flex;
			align-items: center;
			gap: 2px;
			padding: 2px;
			border-radius: var(--radius-pill);
			border: 1px solid var(--auth-chip-border);
			background: var(--auth-chip-bg);
		}

		.segmented button {
			display: flex;
			align-items: center;
			justify-content: center;
			height: 40px;
			min-width: var(--hit-min);
			padding-inline: 14px;
			border: 0;
			border-radius: var(--radius-pill);
			background: transparent;
			color: var(--color-muted);
			font-family: var(--font-mono);
			font-size: var(--text-12);
			letter-spacing: 0.08em;
			line-height: var(--leading-16);
			cursor: pointer;
		}

		.segmented button.active {
			background: color-mix(in oklab, var(--color-text) 8%, transparent);
			color: var(--color-text);
		}
	}
</style>
