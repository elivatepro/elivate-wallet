<!--
	Root hero card, Paper "App — Screens v3" H02/H03/H09: coral felt background,
	left shade, grain, Root bottom-right, title + one line. Mobile 300 px tall,
	desktop 220 px. The card stays dark in both themes (brand surface).
-->
<script lang="ts">
	import RootImage from '#lib/ui/RootImage.svelte';
	import type { RootPose } from '#lib/ui/root.svelte.js';

	let {
		pose,
		title,
		lead,
		compact = false,
		headingLevel = 1
	}: {
		pose: RootPose;
		title: string;
		lead: string;
		/** H09 draws a smaller Root on mobile (150×200). */
		compact?: boolean;
		headingLevel?: 1 | 2;
	} = $props();
</script>

<section class="hero" class:compact>
	<div class="shade" aria-hidden="true"></div>
	<div class="grain" aria-hidden="true"></div>
	<RootImage {pose} class="hero-root" sizes="(min-width: 1024px) 178px, 170px" eager />
	<div class="text">
		<svelte:element this={`h${headingLevel}`} class="title" tabindex="-1">{title}</svelte:element>
		<p class="lead">{lead}</p>
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
		background-image: url('/auth-bg/grain-256.png');
		background-size: 256px 256px;
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

	.text {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 6px;
		width: 176px;
		max-width: 200px;
	}

	.title {
		color: #ffffff;
		font-size: 22px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 27px;
		outline: none;
	}

	.lead {
		color: #d5dadb;
		font-size: 13px;
		line-height: 18px;
	}

	@media (min-width: 1024px) {
		.hero {
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
		.hero.compact :global(.hero-root) {
			right: 72px;
			bottom: -12px;
			width: 178px;
			height: 232px;
		}

		.text {
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
</style>
