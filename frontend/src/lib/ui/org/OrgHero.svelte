<!--
	Org page header card (Paper "App — Screens v2" O01/O07/R01/R05/R07 hero):
	grain-gradient band, a large title, one line, an action row and its own
	Root pose on the right. Dark in both themes, like the BalanceCard recipe.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import type { RootPose } from '#lib/ui/root.svelte.js';

	let {
		pose,
		title,
		line,
		id,
		eyebrow,
		actions
	}: {
		pose: RootPose | null;
		title: string;
		line?: string | null;
		id: string;
		eyebrow?: Snippet;
		actions?: Snippet;
	} = $props();
</script>

<section class="hero" aria-labelledby={id}>
	<div class="shade" aria-hidden="true"></div>
	<div class="grain" aria-hidden="true"></div>
	{#if pose}
		<RootImage {pose} class="hero-root" sizes="(min-width: 1024px) 200px, 120px" eager />
	{/if}
	<div class="text">
		{#if eyebrow}<div class="eyebrow">{@render eyebrow()}</div>{/if}
		<h1 {id}>{title}</h1>
		{#if line}<p class="line">{line}</p>{/if}
	</div>
	{#if actions}<div class="actions">{@render actions()}</div>{/if}
</section>

<style>
	.hero {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: space-between;
		gap: 20px;
		min-height: 156px;
		padding: 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 22px;
		background-color: #1a1d1e;
		background-image: url('/auth-bg/mobile-dark.jpg');
		background-size: cover;
		background-position: 50% 30%;
		background-origin: border-box;
		isolation: isolate;
		color: #f2f4f4;
	}

	.shade,
	.grain {
		position: absolute;
		inset: 0;
		pointer-events: none;
	}

	.shade {
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(18.5% -0.002 -0.003 / 92%) 0%,
			oklab(18.5% -0.002 -0.003 / 55%) 55%,
			oklab(18.5% -0.002 -0.003 / 0%) 100%
		);
	}

	.grain {
		background-image: url('/auth-bg/grain-128.webp');
		background-size: 128px 128px;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}

	.hero :global(.hero-root) {
		position: absolute;
		right: 4px;
		bottom: -12px;
		width: 120px;
		height: 156px;
	}

	.text,
	.actions {
		position: relative;
	}

	.text {
		display: flex;
		flex-direction: column;
		gap: 4px;
		max-width: calc(100% - 116px);
	}

	.eyebrow {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-bottom: 12px;
		color: #d5dadb;
		font-size: var(--text-14);
	}

	h1 {
		overflow-wrap: anywhere;
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 32px;
	}

	.line {
		color: #a9b0b3;
		font-size: 13px;
		line-height: 18px;
	}

	.actions {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 10px;
	}

	.actions :global(.hero-chip) {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		height: 44px;
		padding: 0 18px;
		border: 1px solid #ffffff1f;
		border-radius: var(--radius-pill);
		background: #ffffff14;
		color: #f2f4f4;
		font: inherit;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		text-decoration: none;
		cursor: pointer;
	}

	.actions :global(.hero-chip:disabled) {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	.actions :global(.hero-cta) {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		height: 40px;
		padding: 0 16px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--button-primary-bg);
		box-shadow:
			#ffffff59 0px 1px 0px inset,
			var(--button-primary-glow) 0px 10px 28px -10px;
		color: var(--button-primary-ink);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		text-decoration: none;
		cursor: pointer;
	}

	.actions :global(.hero-cta:disabled) {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	@media (min-width: 1024px) {
		.hero {
			min-height: 220px;
			padding: 32px;
			border-radius: var(--radius-24);
		}

		.hero :global(.hero-root) {
			right: 64px;
			bottom: -14px;
			width: 200px;
			height: 260px;
		}

		h1 {
			font-size: 40px;
			line-height: 44px;
		}

		.line {
			font-size: 15px;
			line-height: 20px;
		}

		.actions :global(.hero-cta) {
			height: 46px;
			padding: 0 20px;
		}
	}
</style>
