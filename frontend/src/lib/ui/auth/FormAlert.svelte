<!--
	Form-level message, announced and focused after a failed POST (plan §4.5).
	Status always carries text, never only colour (P-06).
-->
<script lang="ts">
	import { onMount } from 'svelte';

	let {
		message,
		tone = 'danger',
		reference
	}: { message: string; tone?: 'danger' | 'info'; reference?: string | null } = $props();

	let el: HTMLDivElement | undefined = $state();
	onMount(() => el?.focus());
</script>

<div class="alert" data-tone={tone} role="alert" tabindex="-1" bind:this={el}>
	<p>{message}</p>
	{#if reference}<p class="ref">Reference {reference}</p>{/if}
</div>

<style>
	.alert {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 12px 16px;
		border-radius: var(--radius-12);
		border: 1px solid color-mix(in oklab, var(--tone) 45%, transparent);
		background: color-mix(in oklab, var(--tone) 12%, transparent);
		color: var(--color-text);
		font-size: var(--text-14);
		line-height: var(--leading-20);
		--tone: var(--color-danger);
	}

	.alert[data-tone='info'] {
		--tone: var(--color-info);
	}

	.ref {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}
</style>
