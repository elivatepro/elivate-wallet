<!--
	Confirm a protected change (Paper L02 "Save the new split?", I02 "Revoke
	invitation"): one-line summary, optional reason (3–500), the 4-digit PIN
	when asked, Cancel / confirm. Modal (Bits UI Dialog); focus is trapped and
	returns to the trigger. The PIN is cleared on every open and failure.
-->
<script lang="ts">
	import { Dialog } from 'bits-ui';
	import PinField from '#lib/ui/auth/PinField.svelte';

	let {
		open = $bindable(false),
		title,
		summary,
		confirmLabel,
		cancelLabel = 'Cancel',
		reasonLabel = 'Reason',
		needsReason = true,
		needsPin = true,
		busy = false,
		error = null,
		pinError = null,
		tone = 'accent',
		onConfirm
	}: {
		open?: boolean;
		title: string;
		summary?: string;
		confirmLabel: string;
		cancelLabel?: string;
		reasonLabel?: string;
		needsReason?: boolean;
		needsPin?: boolean;
		busy?: boolean;
		error?: string | null;
		pinError?: string | null;
		tone?: 'accent' | 'danger';
		onConfirm: (input: { reason: string; pin: string | undefined }) => void;
	} = $props();

	let reason = $state('');
	let reasonError = $state<string | null>(null);
	let form: HTMLFormElement | undefined = $state();

	$effect(() => {
		if (open) reasonError = null;
	});

	function submit(event: SubmitEvent) {
		event.preventDefault();
		const data = new FormData(event.currentTarget as HTMLFormElement);
		const pin = String(data.get('pin') ?? '') || undefined;
		const trimmed = reason.trim();
		if (needsReason && (trimmed.length < 3 || trimmed.length > 500)) {
			reasonError = 'Give a reason (3–500 characters).';
			return;
		}
		reasonError = null;
		onConfirm({ reason: trimmed, pin });
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="confirm-overlay" />
		<Dialog.Content
			class="confirm-dialog"
			aria-describedby={summary ? 'confirm-summary' : undefined}
		>
			<form bind:this={form} onsubmit={submit} novalidate>
				<div class="confirm-body">
					<Dialog.Title class="confirm-title">{title}</Dialog.Title>
					{#if summary}<p class="confirm-summary" id="confirm-summary">{summary}</p>{/if}
					{#if error}<p class="confirm-error" role="alert">{error}</p>{/if}
					{#if needsReason}
						<label class="confirm-label" for="confirm-reason">{reasonLabel}</label>
						<textarea
							id="confirm-reason"
							rows="3"
							maxlength="500"
							bind:value={reason}
							aria-invalid={reasonError ? 'true' : undefined}
							aria-describedby={reasonError ? 'confirm-reason-error' : undefined}></textarea>
						{#if reasonError}<p class="confirm-field-error" id="confirm-reason-error">
								{reasonError}
							</p>{/if}
					{/if}
					{#if needsPin && open}
						<PinField id="confirm-pin" name="pin" label="Your PIN" error={pinError} />
					{/if}
				</div>
				<div class="confirm-actions">
					<Dialog.Close class="confirm-cancel" type="button">{cancelLabel}</Dialog.Close>
					<button
						class="confirm-go"
						data-tone={tone}
						type="submit"
						disabled={busy}
						aria-busy={busy}
					>
						{confirmLabel}
					</button>
				</div>
			</form>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.confirm-overlay) {
		position: fixed;
		inset: 0;
		z-index: 50;
		background: color-mix(in oklab, #000 var(--opacity-overlay), transparent);
	}

	:global(.confirm-dialog) {
		position: fixed;
		/* Slice 21: centred with auto margins, not translate(-50%) (blurry text). */
		left: 0;
		right: 0;
		bottom: 0;
		z-index: 51;
		width: min(520px, 100%);
		margin-inline: auto;
		border-radius: 24px 24px 0 0;
		border: 1px solid color-mix(in oklab, var(--color-text) 10%, transparent);
		background: var(--color-surface);
		color: var(--color-text);
		padding-bottom: env(safe-area-inset-bottom);
	}

	@media (min-width: 1024px) {
		:global(.confirm-dialog) {
			top: 150px;
			bottom: auto;
			border-radius: var(--radius-24);
		}
	}

	.confirm-body {
		display: flex;
		flex-direction: column;
		gap: 12px;
		padding: 28px;
	}

	:global(.confirm-title) {
		font-size: var(--text-24);
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.02em;
		line-height: var(--leading-32);
	}

	.confirm-summary {
		margin-top: -6px;
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.confirm-error {
		padding: 10px 14px;
		border-radius: var(--radius-12);
		background: color-mix(in oklab, var(--color-danger) 12%, transparent);
		color: var(--color-text);
		font-size: var(--text-14);
	}

	.confirm-label {
		margin-top: 8px;
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
	}

	textarea {
		min-height: 96px;
		padding: 14px 16px;
		border-radius: var(--radius-12);
		border: 1px solid color-mix(in oklab, var(--color-text) 16%, transparent);
		background: color-mix(in oklab, var(--color-canvas) 60%, transparent);
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		line-height: var(--leading-24);
		resize: vertical;
	}

	textarea:focus {
		outline: none;
		border-color: var(--color-accent);
	}

	.confirm-field-error {
		color: var(--color-danger);
		font-size: var(--text-14);
	}

	.confirm-actions {
		display: flex;
		justify-content: flex-end;
		gap: 12px;
		padding: 20px 28px;
		border-top: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
	}

	:global(.confirm-cancel),
	.confirm-go {
		min-height: 48px;
		padding: 0 22px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	:global(.confirm-cancel) {
		border: 1px solid color-mix(in oklab, var(--color-text) 20%, transparent);
		background: transparent;
		color: var(--color-text);
	}

	.confirm-go {
		border: 0;
		background: var(--button-primary-bg);
		box-shadow: var(--auth-button-shadow);
		color: var(--button-primary-ink);
	}

	.confirm-go[data-tone='danger'] {
		background: var(--color-danger);
		box-shadow: none;
		color: #fff;
	}

	.confirm-go:disabled {
		opacity: var(--opacity-disabled);
	}
</style>
