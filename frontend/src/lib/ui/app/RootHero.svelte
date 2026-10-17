<!--
	Root hero card, Paper "App — Screens v3" H02/H03/H09: coral felt background,
	left shade, grain, Root bottom-right, title + one line. Mobile 300 px tall,
	desktop 220 px. The card stays dark in both themes (brand surface).
	Blueprint 41: `short` (Withdrawals) is 200 px on phones with a 120 px Root;
	desktop is unchanged.
	Blueprint 46: without a `pose` (money, review and record pages) there is no
	Root and the card closes up around its text.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import type { RootPose } from '#lib/ui/root.svelte.js';

	let {
		pose,
		title,
		lead,
		kicker,
		children,
		compact = false,
		card = false,
		short = false,
		headingLevel = 1
	}: {
		/** Blueprint 46: omit on money, review and record pages (no Root). */
		pose?: RootPose | null;
		title: string;
		lead?: string;
		/** Small line above the title (Paper v2 W01 "Reserved for open withdrawals"). */
		kicker?: string;
		/** Extra content under the title (W01 status chips). */
		children?: Snippet;
		/** H09 draws a smaller Root on mobile (150×200). */
		compact?: boolean;
		/** Queue cards under a list (Paper v1 C01/C05/C07/C09, v2 W05): 260 px, 24 px title. */
		card?: boolean;
		/** Blueprint 41 (owner 2026-10-15): a 200 px banner on phones, Root 120 px wide. */
		short?: boolean;
		headingLevel?: 1 | 2;
	} = $props();
</script>

<section class="hero" class:compact class:card class:short class:bare={!pose}>
	<div class="shade" aria-hidden="true"></div>
	<div class="grain" aria-hidden="true"></div>
	{#if pose}
		<RootImage
			{pose}
			class="hero-root"
			sizes={short ? '(min-width: 1024px) 178px, 120px' : '(min-width: 1024px) 178px, 170px'}
			eager
		/>
	{/if}
	<div class="text">
		{#if kicker}<p class="kicker">{kicker}</p>{/if}
		<svelte:element this={`h${headingLevel}`} class="title" tabindex="-1">{title}</svelte:element>
		{#if lead}<p class="lead">{lead}</p>{/if}
		{@render children?.()}
	</div>
</section>

<style>
	.hero {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		flex-shrink: 0;
		height: 300px;
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
			oklab(21.5% -0.004 -0.003 / 92%) 0%,
			oklab(21.5% -0.004 -0.003 / 60%) 55%,
			oklab(21.5% -0.004 -0.003 / 0%) 100%
		);
	}

	.grain {
		background-image: url('/auth-bg/grain-128.webp');
		background-size: 128px 128px;
		background-repeat: repeat;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}

	.hero :global(.hero-root) {
		position: absolute;
		right: 10px;
		bottom: -10px;
		width: 170px;
		height: 228px;
	}

	.hero.compact :global(.hero-root) {
		right: 6px;
		bottom: -6px;
		width: 150px;
		height: 200px;
	}

	.hero.short {
		height: 200px;
		padding: 18px;
	}

	.hero.short :global(.hero-root) {
		right: 8px;
		bottom: -8px;
		width: 120px;
		height: 161px;
	}

	.text {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 6px;
		width: 176px;
		max-width: 200px;
	}

	/* The smaller Root leaves the title and chips more room. */
	.hero.short .text {
		width: auto;
		max-width: calc(100% - 104px);
	}

	/* Blueprint 46: no Root, so no fixed height and the text takes the width. */
	.hero.bare {
		height: auto;
	}

	.hero.bare .text {
		width: auto;
		max-width: none;
	}

	.title {
		color: #ffffff;
		font-size: 22px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 27px;
		outline: none;
	}

	.lead,
	.kicker {
		color: #d5dadb;
		font-size: 13px;
		line-height: 18px;
	}

	@media (min-width: 1024px) {
		.hero,
		.hero.short {
			height: 220px;
			padding: 32px;
			border-radius: var(--radius-24);
		}

		.shade {
			background-image: linear-gradient(
				in oklab 90deg,
				oklab(21.5% -0.004 -0.003 / 92%) 0%,
				oklab(21.5% -0.004 -0.003 / 55%) 55%,
				oklab(21.5% -0.004 -0.003 / 0%) 100%
			);
		}

		.hero :global(.hero-root),
		.hero.compact :global(.hero-root),
		.hero.short :global(.hero-root) {
			right: 72px;
			bottom: -12px;
			width: 178px;
			height: 232px;
		}

		.text,
		.hero.short .text {
			gap: 8px;
			width: auto;
			max-width: none;
		}

		.title {
			font-size: 36px;
			letter-spacing: -0.03em;
			line-height: 42px;
		}

		.lead {
			font-size: 15px;
			line-height: 22px;
		}
	}

	@media (min-width: 1024px) {
		.hero.card {
			height: 260px;
			padding: 28px;
		}

		.hero.card :global(.hero-root) {
			right: 64px;
			bottom: -14px;
			width: 180px;
			height: 242px;
		}

		.hero.card .text {
			max-width: calc(100% - 260px);
			gap: 6px;
		}

		.hero.bare,
		.hero.bare.short,
		.hero.bare.card {
			height: auto;
		}

		.hero.bare.card .text {
			max-width: none;
		}

		.hero.card .title {
			font-size: 24px;
			letter-spacing: -0.01em;
			line-height: 30px;
		}

		.hero.card .lead {
			color: #a9b0b3;
			font-size: 14px;
			line-height: 20px;
		}
	}
</style>
