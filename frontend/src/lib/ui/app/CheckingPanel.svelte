<!--
	"Checking" screen, Paper "App — Screens v1" B16/B16d and "App — Screens v4"
	J04 (income): title, lead, two actions and a mono footnote. Blueprint 46:
	no Root while money is pending (the pocket-watch stage is gone). Presentational; OutcomeUnknown and the income page fill it.
	On desktop the actions sit side by side with the primary on the right.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';

	let {
		title,
		lead,
		footnote = null,
		busy = false,
		actions,
		children
	}: {
		title: string;
		lead: string;
		footnote?: string | null;
		busy?: boolean;
		/** Buttons/links: give the primary class="primary" first, then class="secondary". */
		actions: Snippet;
		children?: Snippet;
	} = $props();
</script>

<section class="outcome" aria-live="polite" aria-busy={busy}>
	<div class="text">
		<h1 class="title" tabindex="-1">{title}</h1>
		<p class="lead">{lead}</p>
	</div>
	{@render children?.()}
	<div class="actions">{@render actions()}</div>
	{#if footnote}<p class="label">{footnote}</p>{/if}
</section>

<style>
	.outcome {
		position: relative;
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 24px;
		padding-top: 64px;
		text-align: center;
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

	.actions :global(.primary),
	.actions :global(.secondary) {
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

	.actions :global(.primary) {
		border: 0;
		background: var(--color-text);
		color: var(--color-canvas);
		font-weight: var(--font-weight-semibold);
	}

	.actions :global(.primary:disabled) {
		opacity: var(--opacity-disabled);
		cursor: progress;
	}

	.actions :global(.secondary) {
		border: 1px solid var(--color-border);
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	@media (min-width: 1024px) {
		.outcome {
			gap: 28px;
			padding: 40px 0 24px;
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

		.actions :global(.primary),
		.actions :global(.secondary) {
			height: 48px;
			font-size: 15px;
			line-height: 18px;
		}

		.actions :global(.primary) {
			padding: 0 26px;
		}

		.actions :global(.secondary) {
			padding: 0 22px;
		}
	}
</style>
