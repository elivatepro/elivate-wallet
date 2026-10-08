<!--
	Unknown-outcome screen, Paper "App — Screens v1" B16 (mobile) / B16d
	(desktop): "Checking your request". Bound to a CommandAttempt; shows the
	attempt's non-secret summary and short label, never a new key.

	The resolved variants (it went through / it didn't go through / still
	checking) are not drawn in Paper yet: they reuse this layout with plain copy
	and are listed as waiting on Paper approval (Blueprint 08).
-->
<script lang="ts">
	import type { Schema } from 'effect';
	import type { CommandAttempt } from '#lib/client/command-attempt.svelte.js';
	import { attemptLabel } from '#lib/recovery.js';
	import RootImage from '#lib/ui/RootImage.svelte';

	let {
		attempt,
		noun = 'request',
		backHref = '/app',
		backLabel = 'Back to Home',
		onResolved
	}: {
		attempt: CommandAttempt<Schema.ConstraintDecoder<unknown>>;
		/** "withdrawal", "income"... used in the copy. */
		noun?: string;
		backHref?: string;
		backLabel?: string;
		/** Called when the person continues after a settled outcome. */
		onResolved?: () => void;
	} = $props();

	const s = $derived(attempt.state);
	const pending = $derived(
		s.kind === 'unknown' || s.kind === 'checking' || s.kind === 'resolved' ? s.attempt : null
	);
	const resolution = $derived(s.kind === 'resolved' ? s.resolution : null);
	const busy = $derived(s.kind === 'checking' || s.kind === 'sending');

	const title = $derived.by(() => {
		switch (resolution?.kind) {
			case 'committed':
				return 'It went through';
			case 'cancelled':
				return 'This attempt was cancelled';
			case 'not_committed':
				return resolution.canResend ? 'It didn’t go through yet' : 'It didn’t go through';
			default:
				return 'Checking your request';
		}
	});

	const lead = $derived.by(() => {
		const what = pending?.summary ? `your ${pending.summary}` : `your ${noun}`;
		switch (resolution?.kind) {
			case 'committed':
				return resolution.reference
					? `We confirmed ${what}. Reference ${resolution.reference}.`
					: `We confirmed ${what}.`;
			case 'cancelled':
				return `Nothing was posted for ${what}.`;
			case 'not_committed':
				return resolution.canResend
					? `Nothing was posted for ${what}. Send it again safely: it can only go through once.`
					: `Nothing was posted for ${what}. You can start again.`;
			case 'conflict':
				return 'We couldn’t match this attempt. Contact support with the attempt code below.';
			default:
				return `We’re confirming ${what}. Don’t send it again.`;
		}
	});

	function finish() {
		attempt.reset();
		onResolved?.();
	}
</script>

<section class="outcome" aria-live="polite" aria-busy={busy}>
	<div class="art" aria-hidden="true">
		<div class="shade"></div>
		<div class="grain"></div>
		<RootImage pose="checking" class="art-root" sizes="(min-width: 1024px) 190px, 210px" eager />
	</div>
	<div class="text">
		<h1 class="title" tabindex="-1">{title}</h1>
		<p class="lead">{lead}</p>
	</div>
	<div class="actions">
		{#if resolution?.kind === 'not_committed' && resolution.canResend}
			<button type="button" class="primary" disabled={busy} onclick={() => attempt.resend()}
				>Send again</button
			>
		{:else if resolution && resolution.kind !== 'pending' && resolution.kind !== 'conflict'}
			<button type="button" class="primary" onclick={finish}>Done</button>
		{:else}
			<button type="button" class="primary" disabled={busy} onclick={() => attempt.check()}
				>{busy ? 'Checking…' : 'Check again'}</button
			>
		{/if}
		<a class="secondary" href={backHref}>{backLabel}</a>
	</div>
	{#if pending}<p class="label">Attempt {attemptLabel(pending.key)}</p>{/if}
</section>

<style>
	.outcome {
		position: relative;
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 24px;
		padding-top: 40px;
		text-align: center;
	}

	.art {
		position: relative;
		display: flex;
		justify-content: center;
		width: 210px;
		height: 284px;
	}

	.shade,
	.grain {
		display: none;
	}

	.art :global(.art-root) {
		width: 210px;
		height: 284px;
	}

	.text {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 10px;
		padding: 0 8px;
	}

	.title {
		color: var(--color-text);
		font-size: 30px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 36px;
		outline: none;
	}

	.lead {
		max-width: 420px;
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: 22px;
	}

	.label {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.actions {
		display: flex;
		flex-direction: column;
		gap: 10px;
		align-self: stretch;
	}

	.primary,
	.secondary {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 54px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: var(--text-16);
		line-height: var(--leading-20);
		text-decoration: none;
		cursor: pointer;
	}

	.primary {
		border: 0;
		background: var(--color-text);
		color: var(--color-canvas);
		font-weight: var(--font-weight-semibold);
	}

	.primary:disabled {
		opacity: var(--opacity-disabled);
		cursor: progress;
	}

	.secondary {
		border: 1px solid var(--color-border);
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	@media (min-width: 1024px) {
		.outcome {
			gap: 28px;
			padding: 40px 0 24px;
		}

		.art {
			width: 640px;
			height: 250px;
			overflow: clip;
			border-radius: 28px;
			background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 50% / cover;
		}

		.shade,
		.grain {
			position: absolute;
			inset: 0;
			display: block;
		}

		.shade {
			background-image: linear-gradient(
				in oklab 180deg,
				oklab(21.5% -0.004 -0.003 / 0%) 30%,
				oklab(21.5% -0.004 -0.003 / 85%) 100%
			);
		}

		.grain {
			background: url('/auth-bg/grain-256.png') 50% / 256px 256px;
			mix-blend-mode: overlay;
			opacity: 0.25;
		}

		.art :global(.art-root) {
			position: absolute;
			bottom: -10px;
			width: 190px;
			height: 256px;
		}

		.title {
			font-size: 36px;
			line-height: 44px;
		}

		.lead {
			font-size: 15px;
			line-height: 24px;
		}

		.actions {
			flex-direction: row-reverse;
			align-self: center;
			gap: 12px;
		}

		.primary,
		.secondary {
			height: 48px;
			font-size: 15px;
			line-height: 18px;
		}

		.primary {
			padding: 0 26px;
		}

		.secondary {
			padding: 0 22px;
		}
	}
</style>
