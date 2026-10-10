<!--
	Compact Root hero for the Profile & security pages, Paper "App — Screens v2"
	S03–S06 (mobile 168 px, desktop 220 px) and "App — Screens v1" B09/B10
	(identity variant with the avatar: mobile 164 px, desktop 180 px). Coral felt
	background, left shade, grain, Root bottom-right; dark in both themes
	(brand surface). Root size/offsets come from each artboard.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import type { RootPose } from '#lib/ui/root.svelte.js';

	interface Place {
		readonly width: number;
		readonly height: number;
		readonly right: number;
		readonly bottom: number;
	}

	let {
		pose,
		mobile,
		desktop,
		identity = false,
		children
	}: {
		pose: RootPose;
		mobile: Place;
		desktop: Place;
		/** B09/B10: avatar + name row instead of a title block. */
		identity?: boolean;
		children: Snippet;
	} = $props();

	const vars = $derived(
		[
			`--m-w:${mobile.width}px`,
			`--m-h:${mobile.height}px`,
			`--m-r:${mobile.right}px`,
			`--m-b:${mobile.bottom}px`,
			`--d-w:${desktop.width}px`,
			`--d-h:${desktop.height}px`,
			`--d-r:${desktop.right}px`,
			`--d-b:${desktop.bottom}px`
		].join(';')
	);
</script>

<section class="hero" class:identity style={vars}>
	<div class="shade" aria-hidden="true"></div>
	<div class="grain" aria-hidden="true"></div>
	<RootImage {pose} class="hero-root" sizes="(min-width: 1024px) 182px, 124px" eager />
	<div class="body">{@render children()}</div>
</section>

<style>
	.hero {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		flex-shrink: 0;
		height: 168px;
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

	.hero.identity {
		height: 164px;
		border-radius: 20px;
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

	.identity .shade {
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(18.5% -0.002 -0.003 / 92%) 0%,
			oklab(18.5% -0.002 -0.003 / 50%) 60%,
			oklab(18.5% -0.002 -0.003 / 0%) 100%
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
		right: var(--m-r);
		bottom: var(--m-b);
		width: var(--m-w);
		height: var(--m-h);
	}

	.body {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	@media (min-width: 1024px) {
		.hero {
			height: 220px;
			padding: 32px;
			border-radius: var(--radius-24);
		}

		.hero.identity {
			flex-direction: row;
			align-items: center;
			justify-content: flex-start;
			height: 180px;
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

		.identity .shade {
			background-image: linear-gradient(
				in oklab 90deg,
				oklab(18.5% -0.002 -0.003 / 92%) 0%,
				oklab(18.5% -0.002 -0.003 / 55%) 55%,
				oklab(18.5% -0.002 -0.003 / 0%) 100%
			);
		}

		.hero :global(.hero-root) {
			right: var(--d-r);
			bottom: var(--d-b);
			width: var(--d-w);
			height: var(--d-h);
		}

		.identity .body {
			flex-direction: row;
			align-items: center;
			gap: 20px;
		}
	}
</style>
