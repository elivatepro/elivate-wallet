<!--
	Auth/onboarding frame from Paper "Authentication v2": GrainGradient background,
	grain overlay, brand row with theme control; mobile stacks content at the
	bottom over a faded background, desktop floats a 460 px glass panel right.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { Theme } from '#lib/theme.js';
	import ThemeSwitch from '#lib/ui/ThemeSwitch.svelte';

	let { theme, children }: { theme: Theme; children: Snippet } = $props();
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
