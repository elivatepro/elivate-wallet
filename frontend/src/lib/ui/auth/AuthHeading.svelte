<!-- Eyebrow (glowing dot + mono label), title and optional lead, per Authentication v2. -->
<script lang="ts">
	import type { Component } from 'svelte';

	let {
		eyebrow,
		title,
		lead,
		tone = 'accent',
		icon
	}: {
		eyebrow: string;
		title: string;
		lead?: string;
		tone?: 'accent' | 'danger';
		icon?: Component<{ size?: number; strokeWidth?: number; 'aria-hidden'?: 'true' }>;
	} = $props();
</script>

<div class="heading" class:with-icon={!!icon} data-tone={tone}>
	{#if icon}
		{@const Icon = icon}
		<div class="tile" aria-hidden="true"><Icon size={24} strokeWidth={1.6} aria-hidden="true" /></div>
	{/if}
	<p class="eyebrow"><span class="dot" aria-hidden="true"></span>{eyebrow}</p>
	<h1 tabindex="-1">{title}</h1>
	{#if lead}<p class="lead">{lead}</p>{/if}
</div>

<style>
	.heading {
		display: flex;
		flex-direction: column;
		gap: 12px;
		--tone: var(--color-accent);
		--tone-label: var(--color-accent-label);
	}

	.heading.with-icon {
		gap: 14px;
	}

	.heading[data-tone='danger'] {
		--tone: var(--color-danger);
		--tone-label: var(--color-danger);
	}

	.tile {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 56px;
		height: 56px;
		border-radius: 18px;
		border: 1px solid #ffffff24;
		background-image: linear-gradient(
			in oklab 160deg,
			oklab(100% 0 0 / 10%) 0%,
			oklab(100% 0 0 / 3%) 100%
		);
		box-shadow:
			#ffffff1f 0px 1px 0px inset,
			color-mix(in oklab, var(--tone) 50%, transparent) 0px 10px 30px -10px;
		color: var(--tone-label);
	}

	.eyebrow {
		display: flex;
		align-items: center;
		gap: 8px;
		color: var(--tone-label);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		letter-spacing: 0.14em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.dot {
		flex-shrink: 0;
		width: 6px;
		height: 6px;
		border-radius: var(--radius-pill);
		background: var(--tone);
		box-shadow: var(--tone) 0px 0px 12px;
	}

	h1 {
		color: var(--color-text);
		font-size: 36px;
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.035em;
		line-height: var(--leading-40);
		outline: none;
	}

	.lead {
		padding-top: 4px;
		color: var(--auth-body);
		font-size: var(--text-16);
		line-height: var(--leading-24);
	}

	.heading:not(.with-icon) .lead {
		padding-top: 0;
	}

	@media (min-width: 1024px) {
		h1 {
			font-size: var(--text-40);
			line-height: 44px;
		}
	}
</style>
