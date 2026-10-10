<!--
	Confirm + PIN for Record income, Paper "App — Screens v4" J02: "Post ₦X?",
	who it lands with, a To / Source / Receipts summary, the 4-digit PIN, Cancel
	and Post income. Centered dialog on desktop, bottom sheet on mobile. While
	posting it can't be dismissed (the attempt is in flight).
-->
<script lang="ts">
	import { Dialog } from 'bits-ui';
	import PinField from '#lib/ui/auth/PinField.svelte';

	let {
		open = $bindable(false),
		title,
		lead,
		rows,
		confirmLabel = 'Post income',
		busy = false,
		error = null,
		pinError = null,
		onConfirm
	}: {
		open?: boolean;
		title: string;
		lead: string;
		rows: ReadonlyArray<{ label: string; value: string }>;
		confirmLabel?: string;
		busy?: boolean;
		error?: string | null;
		pinError?: string | null;
		onConfirm: (input: { pin: string | undefined }) => void;
	} = $props();

	function submit(event: SubmitEvent) {
		event.preventDefault();
		const data = new FormData(event.currentTarget as HTMLFormElement);
		onConfirm({ pin: String(data.get('pin') ?? '') || undefined });
	}

	const hold = (event: Event) => {
		if (busy) event.preventDefault();
	};
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="income-scrim" />
		<Dialog.Content
			class="income-confirm"
			aria-describedby="income-confirm-lead"
			onEscapeKeydown={hold}
			onInteractOutside={hold}
		>
			<form onsubmit={submit} novalidate>
				<span class="handle" aria-hidden="true"></span>
				<div class="head">
					<Dialog.Title class="income-confirm-title">{title}</Dialog.Title>
					<p class="lead" id="income-confirm-lead">{lead}</p>
				</div>
				<div class="body">
					{#if error}<p class="error" role="alert">{error}</p>{/if}
					<dl class="summary">
						{#each rows as row (row.label)}
							<div class="row">
								<dt>{row.label}</dt>
								<dd>{row.value}</dd>
							</div>
						{/each}
					</dl>
					{#if open}
						<PinField id="income-pin" name="pin" label="Your PIN" error={pinError} />
					{/if}
				</div>
				<div class="actions">
					<Dialog.Close class="income-cancel" type="button" disabled={busy}>Cancel</Dialog.Close>
					<button class="go" type="submit" disabled={busy} aria-busy={busy}>{confirmLabel}</button>
				</div>
			</form>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.income-scrim) {
		position: fixed;
		inset: 0;
		z-index: 50;
		background: #0c0e0fad;
	}

	:global(.income-confirm) {
		position: fixed;
		left: 50%;
		bottom: 0;
		z-index: 51;
		width: min(520px, 100%);
		overflow: clip;
		transform: translateX(-50%);
		border: 1px solid var(--color-border);
		border-bottom: 0;
		border-radius: 24px 24px 0 0;
		background: var(--color-surface);
		box-shadow: #00000099 0px 40px 80px -20px;
		color: var(--color-text);
		padding-bottom: env(safe-area-inset-bottom);
	}

	.handle {
		display: block;
		width: 36px;
		height: 4px;
		margin: 12px auto 0;
		border-radius: var(--radius-pill);
		background: var(--color-border);
	}

	.head {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 20px 20px 20px;
	}

	:global(.income-confirm-title) {
		font-size: 24px;
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.02em;
		line-height: 30px;
	}

	.lead {
		color: var(--color-muted);
		font-size: 14px;
		line-height: 20px;
	}

	.body {
		display: flex;
		flex-direction: column;
		gap: 20px;
		padding: 0 20px 24px;
	}

	.error {
		padding: 10px 14px;
		border-radius: var(--radius-12);
		background: color-mix(in oklab, var(--color-danger) 12%, transparent);
		font-size: var(--text-14);
	}

	.summary {
		display: flex;
		flex-direction: column;
		border: 1px solid var(--color-border);
		border-radius: 14px;
	}

	.row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		min-height: 44px;
		padding: 0 16px;
		border-bottom: 1px solid var(--shell-edge, var(--color-border));
		font-size: 14px;
		line-height: 18px;
	}

	.row:last-child {
		border-bottom: 0;
	}

	dt {
		color: var(--color-muted);
	}

	dd {
		overflow-wrap: anywhere;
		text-align: right;
	}

	.actions {
		display: flex;
		gap: 12px;
		padding: 0 20px 20px;
	}

	:global(.income-cancel),
	.go {
		flex: 1;
		height: 48px;
		padding: 0 22px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: 15px;
		line-height: 20px;
		cursor: pointer;
	}

	:global(.income-cancel) {
		border: 1px solid var(--color-border);
		background: transparent;
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.go {
		border: 0;
		background: var(--button-primary-bg);
		box-shadow: var(--button-primary-glow) 0px 12px 32px -8px;
		color: var(--button-primary-ink);
		font-weight: var(--font-weight-semibold);
	}

	.go:disabled,
	:global(.income-cancel:disabled) {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	@media (min-width: 1024px) {
		:global(.income-confirm) {
			top: 190px;
			bottom: auto;
			border-bottom: 1px solid var(--color-border);
			border-radius: 24px;
		}

		.handle {
			display: none;
		}

		.head {
			padding: 28px 28px 20px;
		}

		.body {
			padding: 0 28px 24px;
		}

		.actions {
			justify-content: flex-end;
			padding: 20px 28px 28px;
			border-top: 1px solid #ffffff0f;
		}

		:global(.income-cancel),
		.go {
			flex: 0 0 auto;
		}
	}
</style>
