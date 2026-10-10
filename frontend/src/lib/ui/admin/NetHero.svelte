<!--
	Detail hero, Paper "Admin — Screens v1" A07v2d/A09 (desktop) and A07v2m/A10
	(mobile): felt card with the left shade, grain and Root on the right; title
	+ status pill, one line under it, action buttons at the bottom. Desktop 220
	px. Mobile: the app bar already shows the title, so the card shows the pill,
	the line and the buttons. Optional avatar (account detail). The card stays
	dark in both themes (brand surface), like RootHero.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import Badge from '#lib/ui/admin/Badge.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import type { RootPose } from '#lib/ui/root.svelte.js';
	import type { Tone } from '#lib/admin.js';

	let {
		pose,
		title,
		status,
		tone,
		avatar = null,
		line,
		actions
	}: {
		pose: RootPose;
		title: string;
		status: string;
		tone: Tone;
		/** Initials in a 72 px circle before the title (account detail). */
		avatar?: string | null;
		/** The one line under the title (may contain a mono UID). */
		line: Snippet;
		actions?: Snippet;
	} = $props();
</script>

<section class="hero" aria-label={title}>
	<div class="shade" aria-hidden="true"></div>
	<div class="grain" aria-hidden="true"></div>
	<RootImage {pose} class="hero-root" sizes="(min-width: 1024px) 200px, 140px" eager />
	<div class="head">
		{#if avatar}<span class="avatar" aria-hidden="true">{avatar}</span>{/if}
		<div class="text">
			<div class="title-row">
				<h2>{title}</h2>
				<Badge {tone}>{status}</Badge>
			</div>
			<p class="line">{@render line()}</p>
		</div>
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
		flex-shrink: 0;
		min-height: 220px;
		padding: 32px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: var(--radius-24, 24px);
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 50% 30% / cover border-box;
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
			oklab(22.8% -0.004 -0.003 / 92%) 0%,
			oklab(22.8% -0.004 -0.003 / 55%) 55%,
			oklab(22.8% -0.004 -0.003 / 0%) 100%
		);
	}
	.grain {
		background: url('/auth-bg/grain-128.webp') repeat 50% / 128px 128px;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}
	.hero :global(.hero-root) {
		position: absolute;
		right: 56px;
		bottom: -18px;
		width: 200px;
		height: 260px;
	}
	.head {
		position: relative;
		display: flex;
		align-items: center;
		gap: 20px;
		max-width: calc(100% - 260px);
	}
	.avatar {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 72px;
		height: 72px;
		border-radius: 999px;
		border: 1px solid #343a3c;
		background: #232728;
		font-size: 24px;
		font-weight: 600;
		line-height: 28px;
		color: #f2f4f4;
	}
	.text {
		display: flex;
		flex-direction: column;
		gap: 8px;
		min-width: 0;
	}
	.title-row {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 12px;
	}
	.title-row :global(.badge) {
		padding: 3px 10px;
		font-size: 13px;
		line-height: 18px;
	}
	h2 {
		margin: 0;
		font-size: 40px;
		font-weight: 600;
		letter-spacing: -0.02em;
		line-height: 44px;
		color: #f2f4f4;
	}
	.line {
		margin: 0;
		font-size: 15px;
		line-height: 20px;
		color: #a9b0b3;
	}
	.line :global(.mono) {
		font-family: var(--font-mono);
		font-size: 13px;
		letter-spacing: 0.02em;
		color: #d5dadb;
	}
	.actions {
		position: relative;
		display: flex;
		flex-wrap: wrap;
		gap: 10px;
	}
	.actions :global(.btn) {
		min-height: 44px;
		padding: 0 18px;
		border-color: #343a3c;
		background: #111314b3;
		color: #f2f4f4;
	}
	.actions :global(.btn:hover) {
		background: #1a1d1ee6;
	}
	@media (max-width: 1023px) {
		.hero {
			gap: 16px;
			min-height: 0;
			padding: 20px;
			border-radius: 22px;
		}
		.hero :global(.hero-root) {
			right: 4px;
			bottom: -8px;
			width: 120px;
			height: 160px;
		}
		.head {
			max-width: calc(100% - 110px);
		}
		.avatar,
		h2 {
			display: none;
		}
		.line {
			font-size: 13px;
			line-height: 18px;
		}
		.actions {
			max-width: calc(100% - 40px);
		}
		.actions :global(.btn) {
			min-height: 40px;
			padding: 0 14px;
			font-size: 13px;
		}
	}
</style>
