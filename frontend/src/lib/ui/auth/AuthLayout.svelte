<!--
	Auth/onboarding frame from Paper "Authentication v2": GrainGradient background,
	grain overlay, brand row with theme control; mobile stacks content at the
	bottom over a faded background, desktop floats a 460 px glass panel right.
	Gate screens that call useRoot() get the "App — Screens v3" G-layout: Root
	above the heading on mobile, Root on the left and a 500 px panel on desktop.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { Theme } from '#lib/theme.js';
	import ThemeSwitch from '#lib/ui/ThemeSwitch.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import { provideRootStage } from '#lib/ui/root.svelte.js';

	let { theme, children }: { theme: Theme; children: Snippet } = $props();

	const stage = provideRootStage();
</script>

<div class="auth">
	<div class="bg" aria-hidden="true"></div>
	<div class="grain" aria-hidden="true"></div>
	<div class="frame">
		<header class="top">
			<a class="brand" href="/sign-in">
				<img src="/icons/mark.svg" alt="" width="28" height="28" />
				<span>Elivate Wallet</span>
			</a>
			<ThemeSwitch {theme} />
		</header>
		<main class="content">
			<div class="panel">
				{@render children()}
			</div>
			{#if stage.pose}
				<div class="stage" data-size={stage.size}>
					<RootImage
						pose={stage.pose}
						sizes="(min-width: 1024px) 390px, 180px"
						class="stage-root"
						eager
					/>
				</div>
			{/if}
		</main>
	</div>
</div>

<style>
	.auth {
		position: relative;
		min-height: 100dvh;
		background: var(--auth-canvas);
		overflow: clip;
		isolation: isolate;
	}

	.bg {
		position: absolute;
		inset: 0 0 auto 0;
		height: 560px;
		background-image: var(--auth-bg-mobile);
		background-position: 50%;
		background-size: cover;
		z-index: -2;
	}

	.bg::after {
		content: '';
		position: absolute;
		left: 0;
		right: 0;
		top: 200px;
		height: 360px;
		background-image: linear-gradient(
			in oklab 180deg,
			oklab(from var(--auth-fade) l a b / 0%) 0%,
			oklab(from var(--auth-fade) l a b / 70%) 40%,
			var(--auth-fade) 75%
		);
	}

	.grain {
		position: absolute;
		inset: 0;
		background-image: url('/auth-bg/grain-256.png');
		background-repeat: repeat;
		background-size: 256px 256px;
		mix-blend-mode: var(--auth-grain-blend);
		opacity: var(--auth-grain-opacity);
		z-index: -1;
		pointer-events: none;
	}

	.frame {
		display: flex;
		flex-direction: column;
		min-height: 100dvh;
		padding-top: env(safe-area-inset-top);
		padding-bottom: env(safe-area-inset-bottom);
	}

	.top {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 25px 20px 0 24px;
	}

	.brand {
		display: flex;
		align-items: center;
		gap: 10px;
		min-height: var(--hit-min);
		text-decoration: none;
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.01em;
		line-height: var(--leading-20);
	}

	.brand img {
		flex-shrink: 0;
	}

	.content {
		display: flex;
		flex-direction: column;
		flex-grow: 1;
		justify-content: flex-end;
		padding: 48px 24px 32px;
	}

	.panel {
		display: flex;
		flex-direction: column;
		gap: 28px;
		width: 100%;
		max-width: 460px;
		margin-inline: auto;
	}

	/* Gate screens with Root (Paper "App — Screens v3" G01–G12). */
	.content:has(.stage) {
		gap: 28px;
	}

	.stage {
		order: -1;
		display: flex;
		justify-content: center;
	}

	.stage :global(.stage-root) {
		width: 180px;
		height: 240px;
	}

	.stage[data-size='md'] :global(.stage-root) {
		width: 150px;
		height: 200px;
	}

	.stage[data-size='sm'] :global(.stage-root) {
		width: 120px;
		height: 160px;
	}

	.content:has(.stage) :global(.lead) {
		color: var(--color-muted);
		font-size: 15px;
		line-height: 22px;
	}

	@media (min-width: 1024px) {
		.bg {
			height: 100%;
			background-image: var(--auth-bg-desktop);
		}

		.bg::after {
			display: none;
		}

		.frame {
			padding: 32px 64px 40px;
		}

		.top {
			padding: 0;
		}

		.brand {
			gap: 12px;
		}

		.brand img {
			width: 32px;
			height: 32px;
		}

		.content {
			flex-direction: row;
			align-items: center;
			justify-content: flex-end;
			padding: 32px 0 0;
		}

		.panel {
			flex-shrink: 0;
			width: 460px;
			margin: 0;
			gap: 32px;
			padding: 40px;
			border: 1px solid #ffffff17;
			border-radius: var(--radius-24);
			background-image: linear-gradient(
				in oklab 160deg,
				oklab(24.5% -0.003 -0.005 / 86%) 0%,
				oklab(18% -0.002 -0.003 / 90%) 100%
			);
			box-shadow:
				#ffffff0f 0px 1px 0px inset,
				#00000099 0px 40px 80px -20px;
			backdrop-filter: blur(28px);
		}

		.frame:has(.stage) {
			padding-bottom: 48px;
		}

		.content:has(.stage) {
			justify-content: space-between;
			gap: 0;
		}

		.stage {
			flex: 1 1 0%;
			align-self: stretch;
			align-items: center;
		}

		.stage :global(.stage-root),
		.stage[data-size] :global(.stage-root) {
			width: 390px;
			height: 520px;
		}

		.content:has(.stage) .panel {
			width: 500px;
			gap: 28px;
			padding: 40px 64px 48px;
			border-radius: 28px;
		}

		.content:has(.stage) :global(h1) {
			font-size: var(--text-32);
			line-height: 36px;
		}

		.content:has(.stage) :global(.lead) {
			color: var(--auth-body);
			font-size: var(--text-16);
			line-height: var(--leading-24);
		}

		:global([data-theme='light']) .panel {
			border-color: var(--color-border);
			background: #fffffff0;
			box-shadow: #21262814 0px 40px 80px -20px;
		}
	}

	@media (min-width: 1024px) and (prefers-color-scheme: light) {
		:global([data-theme='system']) .panel {
			border-color: var(--color-border);
			background: #fffffff0;
			box-shadow: #21262814 0px 40px 80px -20px;
		}
	}
</style>
