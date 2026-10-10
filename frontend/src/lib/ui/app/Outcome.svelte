<!--
	Outcome screens, Paper "App — Screens v4" J03 (posted), J04 (checking what
	happened), J05 (couldn't record), MV01–MV05 (money moves) and "App —
	Screens v2" W09/W10 (sent for checking, with its status chip). Desktop: a 640×250 grain
	stage with Root, then title, lead, actions and a mono footnote. Mobile: a
	full-height screen with Root on the page grain and the actions at the
	bottom, primary first.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import type { RootPose } from '#lib/ui/root.svelte.js';

	let {
		pose,
		title,
		lead,
		footnote = null,
		chip = null,
		alert,
		actions
	}: {
		pose: RootPose;
		title: string;
		lead: string;
		footnote?: string | null;
		/** W09 "Checking proof · no balance change yet". */
		chip?: string | null;
		alert?: Snippet;
		actions: Snippet;
	} = $props();
</script>

<section class="outcome" aria-labelledby="outcome-title">
	<div class="grain" aria-hidden="true"></div>
	<div class="stage" aria-hidden="true">
		<div class="shade"></div>
		<div class="stage-grain"></div>
		<RootImage {pose} class="stage-root" sizes="(min-width: 1024px) 190px, 210px" eager />
	</div>
	<div class="message">
		{#if chip}<span class="chip">{chip}</span>{/if}
		<h1 id="outcome-title" class="title">{title}</h1>
		<p class="lead">{lead}</p>
		{#if footnote}<p class="footnote footnote-mobile">{footnote}</p>{/if}
	</div>
	{#if alert}<div class="alert">{@render alert()}</div>{/if}
	<div class="actions">{@render actions()}</div>
	{#if footnote}<p class="footnote footnote-desktop">{footnote}</p>{/if}
</section>

<style>
	/* ── Mobile (J03–J05 mobile) ─────────────────────────────────── */

	.outcome {
		position: relative;
		display: flex;
		flex: 1;
		flex-direction: column;
		min-height: calc(100dvh - env(safe-area-inset-top));
		padding-top: calc(62px + env(safe-area-inset-top));
	}

	.grain {
		position: absolute;
		inset: 0;
		/* Blueprint 20 B8: the 128 px tile, four times, fills the same centred 256 px square. */
		background:
			url('/auth-bg/grain-128.webp') calc(50% - 64px) calc(50% - 64px) / 128px 128px no-repeat,
			url('/auth-bg/grain-128.webp') calc(50% + 64px) calc(50% - 64px) / 128px 128px no-repeat,
			url('/auth-bg/grain-128.webp') calc(50% - 64px) calc(50% + 64px) / 128px 128px no-repeat,
			url('/auth-bg/grain-128.webp') calc(50% + 64px) calc(50% + 64px) / 128px 128px no-repeat;
		mix-blend-mode: overlay;
		opacity: 0.2;
		pointer-events: none;
	}

	.stage {
		position: relative;
		display: flex;
		justify-content: center;
		padding-top: 40px;
	}

	.shade,
	.stage-grain {
		display: none;
	}

	.stage :global(.stage-root) {
		width: 210px;
		height: 284px;
	}

	.message {
		position: relative;
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 10px;
		padding: 24px 28px 0;
		text-align: center;
	}

	.chip {
		padding: 3px 12px;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--color-info) 18%, transparent);
		color: var(--color-info);
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.title {
		color: var(--color-text);
		font-size: 30px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 36px;
	}

	.lead {
		color: var(--color-muted);
		font-size: 14px;
		line-height: 22px;
	}

	.footnote {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 12px;
		line-height: 16px;
	}

	.footnote-mobile {
		padding-top: 4px;
	}

	.footnote-desktop {
		display: none;
	}

	.alert {
		position: relative;
		padding: 16px 20px 0;
	}

	.actions {
		position: relative;
		display: flex;
		flex: 1;
		flex-direction: column-reverse;
		gap: 10px;
		padding: 24px 20px calc(34px + env(safe-area-inset-bottom));
	}

	/* The column is reversed so the primary (last in the DOM) sits on top. */
	.actions :global(.out-primary),
	.actions :global(.out-ghost) {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 54px;
		padding: 0 26px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: 16px;
		line-height: 20px;
		text-decoration: none;
		cursor: pointer;
	}

	.actions :global(.out-primary) {
		border: 0;
		background: var(--color-text);
		color: var(--color-canvas);
		font-weight: var(--font-weight-semibold);
	}

	.actions :global(.out-ghost) {
		border: 1px solid var(--color-border);
		background: transparent;
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.actions :global(button:disabled) {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	@media (max-width: 1023px) {
		.actions {
			margin-top: auto;
			flex: 0 0 auto;
		}
	}

	/* ── Desktop (J03–J05 desktop) ───────────────────────────────── */

	@media (min-width: 1024px) {
		.outcome {
			align-items: center;
			gap: 28px;
			min-height: 0;
			padding: 40px 0 24px;
		}

		.grain {
			display: none;
		}

		.stage {
			overflow: clip;
			width: min(640px, 100%);
			height: 250px;
			padding: 0;
			border-radius: 28px;
			background: var(--color-surface) url('/root/stage.webp') 50% / cover;
		}

		.shade {
			position: absolute;
			inset: 0;
			display: block;
			background: linear-gradient(
				in oklab 180deg,
				oklab(21.5% -0.004 -0.003 / 0%) 30%,
				oklab(21.5% -0.004 -0.003 / 85%) 100%
			);
		}

		.stage-grain {
			position: absolute;
			inset: 0;
			display: block;
			/* Blueprint 20 B8: the 128 px tile, four times, fills the same centred 256 px square. */
			background:
				url('/auth-bg/grain-128.webp') calc(50% - 64px) calc(50% - 64px) / 128px 128px no-repeat,
				url('/auth-bg/grain-128.webp') calc(50% + 64px) calc(50% - 64px) / 128px 128px no-repeat,
				url('/auth-bg/grain-128.webp') calc(50% - 64px) calc(50% + 64px) / 128px 128px no-repeat,
				url('/auth-bg/grain-128.webp') calc(50% + 64px) calc(50% + 64px) / 128px 128px no-repeat;
			mix-blend-mode: overlay;
			opacity: 0.25;
		}

		.stage :global(.stage-root) {
			position: absolute;
			bottom: -10px;
			width: 190px;
			height: 256px;
		}

		.message {
			padding: 0;
		}

		.title {
			font-size: 36px;
			line-height: 44px;
		}

		.lead {
			max-width: 420px;
			font-size: 15px;
			line-height: 24px;
		}

		.footnote-mobile {
			display: none;
		}

		.footnote-desktop {
			display: block;
			margin-top: -12px;
		}

		.alert {
			width: min(520px, 100%);
			padding: 0;
		}

		.actions {
			flex: 0 0 auto;
			flex-direction: row;
			gap: 12px;
			padding: 0;
		}

		.actions :global(.out-primary),
		.actions :global(.out-ghost) {
			height: 48px;
			font-size: 15px;
			line-height: 18px;
		}

		.actions :global(.out-ghost) {
			padding: 0 22px;
		}
	}
</style>
