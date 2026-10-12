<!--
	Coral gradient pill with the dark arrow chip (Authentication v2). Submit,
	link, or (with onclick) a plain button. Blueprint 35: the chip icon can change.
-->
<script lang="ts">
	import type { Component } from 'svelte';
	import ArrowRight from '@lucide/svelte/icons/arrow-right';

	let {
		label,
		href,
		busy = false,
		disabled = false,
		name,
		value,
		icon: Icon = ArrowRight,
		onclick
	}: {
		label: string;
		href?: string;
		busy?: boolean;
		disabled?: boolean;
		name?: string;
		value?: string;
		icon?: Component<{ size?: number; strokeWidth?: number }>;
		onclick?: () => void;
	} = $props();
</script>

{#if href}
	<a class="primary" {href}>
		<span>{label}</span>
		<span class="chip" aria-hidden="true"><Icon size={18} strokeWidth={2} /></span>
	</a>
{:else}
	<button
		class="primary"
		type={onclick ? 'button' : 'submit'}
		{onclick}
		{name}
		{value}
		disabled={disabled || busy}
		aria-busy={busy ? 'true' : undefined}
	>
		<span>{label}</span>
		<span class="chip" aria-hidden="true"><Icon size={18} strokeWidth={2} /></span>
	</button>
{/if}

<style>
	.primary {
		display: flex;
		align-items: center;
		justify-content: space-between;
		flex-shrink: 0;
		width: 100%;
		height: 56px;
		padding: 0 8px 0 24px;
		border: 0;
		border-radius: var(--radius-pill);
		background-image: var(--button-primary-bg);
		box-shadow: var(--auth-button-shadow);
		color: var(--button-primary-ink);
		font-size: var(--text-16);
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-20);
		text-decoration: none;
		cursor: pointer;
	}

	.primary:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	.chip {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 40px;
		height: 40px;
		border-radius: var(--radius-pill);
		background: var(--button-primary-ink);
		color: var(--button-primary-chip-arrow);
	}

	.primary:focus-visible {
		outline-offset: 3px;
	}
</style>
