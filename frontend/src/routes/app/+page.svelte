<!--
	Home placeholder (M1). Truthful empty state until the ledger slice exists:
	no balances, no demo values (P-06, W-00).
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import type { Shell } from '#lib/client/shell.svelte.js';

	const shell = getContext<Shell>('shell');
</script>

<section class="home" aria-busy={shell.state.kind === 'loading'}>
	{#if shell.state.kind === 'loading'}
		<div class="skeleton" aria-hidden="true"></div>
		<p class="visually-hidden">Loading your workspace</p>
	{:else}
		<h1>Home</h1>
		<p>Your wallet will appear here once income is recorded in this workspace.</p>
	{/if}
</section>

<style>
	.home {
		display: flex;
		flex-direction: column;
		gap: 8px;
		max-width: 560px;
	}

	h1 {
		font-size: var(--text-32);
		font-weight: var(--font-weight-bold);
		line-height: var(--leading-40);
		letter-spacing: var(--tracking-display);
	}

	p {
		color: var(--color-muted);
	}

	.skeleton {
		height: 120px;
		border-radius: var(--radius-16);
		background: var(--color-surface);
	}
</style>
