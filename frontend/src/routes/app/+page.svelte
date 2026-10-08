<!--
	Home, Paper "App — Screens v3" H09 (no income yet). Truthful until the ledger
	reads are wired: no balances, no demo values (P-06, W-00).
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import RootHero from '#lib/ui/app/RootHero.svelte';

	const shell = getContext<Shell>('shell');
</script>

{#if shell.state.kind === 'loading'}
	<div class="skeleton" aria-hidden="true"></div>
	<p class="visually-hidden" role="status">Loading your workspace</p>
{:else}
	<RootHero
		pose="home-empty"
		title="No money in yet"
		lead="Your pockets fill up when income is recorded."
		compact
	/>
{/if}

<style>
	.skeleton {
		height: 300px;
		border-radius: 22px;
		background: var(--color-surface);
	}

	@media (min-width: 1024px) {
		.skeleton {
			height: 220px;
			border-radius: var(--radius-24);
		}
	}
</style>
