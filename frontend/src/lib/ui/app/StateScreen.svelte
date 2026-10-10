<!--
	Whole-page state, Paper "App — Screens v2" X01–X04 (404 and no access):
	Root, a mono eyebrow, title, one line and the actions. Desktop: a surface
	card filling the content area (padding 48, radius 20). Mobile: no card, a
	centred column with the actions stacked full width, primary first.
	Used by NoAccess, PausedView and the error pages.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import type { RootPose } from '#lib/ui/root.svelte.js';

	let {
		pose,
		eyebrow,
		title,
		lead,
		headingLevel = 1,
		wide = false,
		children,
		actions
	}: {
		pose: RootPose;
		eyebrow: string;
		title: string;
		lead?: string;
		headingLevel?: 1 | 2;
		/** X03/X04 draw the velvet rope wider (220×260 / 190×228). */
		wide?: boolean;
		/** Extra lines under the lead (error reference). */
		children?: Snippet;
		/** `.state-primary` / `.state-ghost` links or buttons. */
		actions: Snippet;
	} = $props();
</script>

<section class="state" class:wide aria-labelledby="state-title">
	<RootImage {pose} class="state-root" sizes="(min-width: 1024px) 220px, 190px" eager />
	<p class="eyebrow">{eyebrow}</p>
	<svelte:element this={`h${headingLevel}`} id="state-title" class="title" tabindex="-1"
		>{title}</svelte:element
	>
	{#if lead}<p class="lead">{lead}</p>{/if}
	{@render children?.()}
	<div class="actions">{@render actions()}</div>
</section>

<style>
	/* ── Mobile (X02/X04) ─────────────────────────────────────────── */

	.state {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 14px;
		padding: 40px 4px 24px;
		text-align: center;
	}

	.state :global(.state-root) {
		flex-shrink: 0;
		width: 170px;
		height: 228px;
	}

	.state.wide :global(.state-root) {
		width: 190px;
	}

	.eyebrow {
		padding-top: 8px;
		color: var(--color-accent-text);
		font-family: var(--font-mono);
		font-size: 12px;
		letter-spacing: 0.06em;
		line-height: 16px;
		text-transform: uppercase;
	}

	.title {
		color: var(--color-text);
		font-size: 26px;
		font-weight: var(--font-weight-bold);
		letter-spacing: var(--tracking-display);
		line-height: 32px;
	}

	.title:focus {
		outline: none;
	}

	.lead {
		max-width: 420px;
		color: var(--color-muted);
		font-size: 15px;
		line-height: 22px;
	}

	.actions {
		display: flex;
		flex-direction: column;
		align-self: stretch;
		gap: 12px;
		padding-top: 16px;
	}

	.actions :global(.state-primary),
	.actions :global(.state-ghost) {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		min-height: 52px;
		padding: 0 24px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: 15px;
		line-height: 18px;
		text-decoration: none;
		cursor: pointer;
	}

	.actions :global(.state-primary) {
		border: 0;
		background: var(--button-primary-bg);
		box-shadow:
			#ffffff59 0 1px 0 inset,
			var(--button-primary-glow) 0 10px 28px -10px;
		color: var(--button-primary-ink);
		font-weight: var(--font-weight-semibold);
	}

	.actions :global(.state-ghost) {
		border: 1px solid var(--color-border);
		background: transparent;
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.actions :global(.state-ghost svg) {
		color: var(--color-muted);
	}

	.actions :global(.state-key) {
		display: none;
	}

	/* ── Desktop (X01/X03) ────────────────────────────────────────── */

	@media (min-width: 1024px) {
		.state {
			flex: 1;
			justify-content: center;
			gap: 16px;
			min-height: 560px;
			padding: 48px;
			border: 1px solid color-mix(in srgb, var(--color-text) 8%, transparent);
			border-radius: 20px;
			background: var(--color-surface);
		}

		.state :global(.state-root) {
			width: 200px;
			height: 260px;
		}

		.state.wide :global(.state-root) {
			width: 220px;
		}

		.title {
			font-size: 32px;
			line-height: 40px;
		}

		.actions {
			flex-flow: row wrap;
			align-self: center;
			justify-content: center;
			padding-top: 12px;
		}

		.actions :global(.state-primary),
		.actions :global(.state-ghost) {
			min-height: 48px;
		}

		.actions :global(.state-ghost) {
			gap: 10px;
			padding: 0 22px;
		}

		/* X01 draws the shortcut chip instead of the search icon. */
		.actions :global(.state-ghost .state-icon) {
			display: none;
		}

		.actions :global(.state-key) {
			display: inline-block;
			padding: 3px 6px;
			border-radius: 6px;
			background: var(--color-raised);
			color: var(--color-muted);
			font-family: var(--font-mono);
			font-size: 11px;
			font-weight: var(--font-weight-medium);
			line-height: 14px;
		}
	}
</style>
