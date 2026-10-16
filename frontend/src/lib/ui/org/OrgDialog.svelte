<!--
	Org command dialog (Paper "App — Screens v2" O04/O10/O12/R03/R09/R11/R13
	desktop, O06/O11/O13/R10/R12/R14 mobile): desktop is a 520px modal with a
	grain band holding the title and its own Root pose; mobile is a bottom sheet
	with Root peeking above it. Extra fields come in as children; a reason
	(3–500) and the 4-digit PIN (step-up, A-05) are built in. Bits UI Dialog:
	focus is trapped and returns to the trigger. Blueprint 43: on phones the
	sheet closes with a drag down (not while busy).
-->
<script lang="ts">
	import { enterMovesOn } from '#lib/ui/enter-moves-on.js';
	import type { Snippet } from 'svelte';
	import { Dialog } from 'bits-ui';
	import { busyLabel } from '#lib/ui/busy-label.js';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import { sheetDrag } from '#lib/ui/sheet-drag.js';
	import type { RootPose } from '#lib/ui/root.svelte.js';

	let {
		open = $bindable(false),
		pose,
		title,
		subtitle,
		confirmLabel,
		mobileConfirmLabel,
		tone = 'accent',
		needsReason = true,
		reasonLabel = 'Reason',
		needsPin = true,
		busy = false,
		error = null,
		pinError = null,
		wide = false,
		cancelLabel = 'Cancel',
		secondary,
		children,
		validate,
		onConfirm
	}: {
		open?: boolean;
		pose: RootPose;
		title: string;
		subtitle?: string;
		confirmLabel: string;
		mobileConfirmLabel?: string;
		tone?: 'accent' | 'danger';
		needsReason?: boolean;
		reasonLabel?: string;
		needsPin?: boolean;
		busy?: boolean;
		error?: string | null;
		pinError?: string | null;
		wide?: boolean;
		cancelLabel?: string;
		/** Replaces the cancel button (Paper PL09d "Turn off auto-renew"). */
		secondary?: Snippet;
		children?: Snippet;
		/** Extra field checks; return a message to stop the submit. */
		validate?: () => string | null;
		onConfirm: (input: { reason: string; pin: string | undefined }) => void;
	} = $props();

	let reason = $state('');
	let reasonError = $state<string | null>(null);
	let localError = $state<string | null>(null);

	$effect(() => {
		if (open) {
			reasonError = null;
			localError = null;
		}
	});

	function submit(event: SubmitEvent) {
		event.preventDefault();
		const data = new FormData(event.currentTarget as HTMLFormElement);
		const pin = String(data.get('pin') ?? '') || undefined;
		const trimmed = reason.trim();
		localError = validate?.() ?? null;
		if (needsReason && (trimmed.length < 3 || trimmed.length > 500)) {
			reasonError = 'Give a reason (3–500 characters).';
			return;
		}
		reasonError = null;
		if (localError) return;
		onConfirm({ reason: trimmed, pin });
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="org-scrim" />
		<Dialog.Content class={wide ? 'org-dialog wide' : 'org-dialog'}>
			<RootImage {pose} class="org-dialog-peek" sizes="120px" />
			<form
				class="org-form"
				onsubmit={submit}
				novalidate
				{@attach enterMovesOn}
				{@attach sheetDrag({
					close: () => (open = false),
					canClose: () => !busy,
					panel: (form) => form.closest<HTMLElement>('.org-dialog') ?? form
				})}
			>
				<header class="org-band" data-sheet-grab>
					<div class="org-shade" aria-hidden="true"></div>
					<RootImage {pose} class="org-dialog-root" sizes="140px" />
					<span class="org-handle" aria-hidden="true"></span>
					<Dialog.Title class="org-dialog-title">{title}</Dialog.Title>
					{#if subtitle}<Dialog.Description class="org-dialog-sub">{subtitle}</Dialog.Description
						>{/if}
				</header>
				<div class="org-body">
					{#if error || localError}<p class="org-dialog-error" role="alert">
							{error ?? localError}
						</p>{/if}
					{@render children?.()}
					{#if needsReason}
						<div class="o-field">
							<label for="org-reason">{reasonLabel}</label>
							<textarea
								id="org-reason"
								class="o-input"
								rows="3"
								maxlength="500"
								bind:value={reason}
								aria-invalid={reasonError ? 'true' : undefined}
								aria-describedby={reasonError ? 'org-reason-error' : undefined}></textarea>
							{#if reasonError}<p class="o-field-error" id="org-reason-error">{reasonError}</p>{/if}
						</div>
					{/if}
					{#if needsPin && open}
						<PinField id="org-pin" name="pin" label="Your PIN" error={pinError} />
					{/if}
				</div>
				<div class="org-actions">
					{#if secondary}{@render secondary()}{:else}<Dialog.Close class="org-cancel" type="button"
							>{cancelLabel}</Dialog.Close
						>{/if}
					<button class="org-go" data-tone={tone} type="submit" disabled={busy} aria-busy={busy}>
						<!-- Blueprint 41: working shows a spinner and says so. -->
						{#if busy}<span class="ew-spinner" aria-hidden="true"></span>{busyLabel(
								confirmLabel
							)}{:else}<span class="o-wide">{confirmLabel}</span><span class="o-narrow"
								>{mobileConfirmLabel ?? confirmLabel}</span
							>{/if}
					</button>
				</div>
			</form>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.org-scrim) {
		position: fixed;
		inset: 0;
		z-index: 50;
		background: #08090a9e;
	}

	:global(.org-dialog) {
		position: fixed;
		left: 0;
		right: 0;
		bottom: 0;
		z-index: 51;
		max-height: calc(100dvh - 160px);
		border-top: 1px solid var(--color-border);
		border-radius: 28px 28px 0 0;
		background: var(--color-surface);
		color: var(--color-text);
	}

	.org-form {
		display: flex;
		flex-direction: column;
		max-height: inherit;
		overflow-y: auto;
		padding-bottom: env(safe-area-inset-bottom);
	}

	:global(.org-dialog-peek) {
		position: absolute;
		left: 24px;
		top: -134px;
		width: 118px;
		height: 152px;
		pointer-events: none;
	}

	.org-band {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 10px 20px 0;
	}

	.org-shade,
	.org-band :global(.org-dialog-root) {
		display: none;
	}

	.org-handle {
		align-self: center;
		width: 40px;
		height: 5px;
		margin-bottom: 12px;
		border-radius: var(--radius-pill);
		background: #3e4548;
	}

	:global(.org-dialog-title) {
		position: relative;
		font-size: 24px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.01em;
		line-height: 30px;
	}

	:global(.org-dialog-sub) {
		position: relative;
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.org-body {
		display: flex;
		flex-direction: column;
		gap: 16px;
		padding: 16px 20px 8px;
	}

	.org-dialog-error {
		padding: 10px 14px;
		border-radius: var(--radius-12);
		background: color-mix(in oklab, var(--color-danger) 12%, transparent);
		font-size: var(--text-14);
	}

	.org-actions {
		display: flex;
		gap: 12px;
		padding: 16px 20px 28px;
	}

	:global(.org-cancel),
	.org-go {
		display: flex;
		flex: 1;
		align-items: center;
		justify-content: center;
		gap: 8px;
		height: 52px;
		padding: 0 22px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: 15px;
		line-height: 18px;
		cursor: pointer;
	}

	:global(.org-cancel) {
		border: 1px solid var(--color-border);
		background: transparent;
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.org-go {
		border: 0;
		background: var(--button-primary-bg);
		box-shadow:
			#ffffff59 0px 1px 0px inset,
			var(--button-primary-glow) 0px 10px 28px -10px;
		color: var(--button-primary-ink);
		font-weight: var(--font-weight-semibold);
	}

	.org-go[data-tone='danger'] {
		background: color-mix(in oklab, var(--color-danger) 18%, var(--color-surface));
		box-shadow: none;
		color: var(--color-danger);
	}

	.org-go:disabled:not([aria-busy='true']) {
		opacity: var(--opacity-disabled);
	}

	.org-go[aria-busy='true'] {
		cursor: progress;
	}

	@media (min-width: 1024px) {
		:global(.org-dialog) {
			/* Slice 21: centred with auto margins, not translate(-50%) (blurry text). */
			inset: 0;
			width: 520px;
			height: fit-content;
			max-height: calc(100dvh - 80px);
			margin: auto;
			overflow: clip;
			border: 1px solid var(--color-border);
			border-radius: 24px;
			box-shadow: #00000080 0px 30px 80px;
		}

		:global(.org-dialog.wide) {
			width: 560px;
		}

		:global(.org-dialog-peek) {
			display: none;
		}

		.org-band {
			justify-content: flex-end;
			gap: 0;
			height: 150px;
			flex-shrink: 0;
			padding: 24px 28px;
			overflow: clip;
			background-color: #1a1d1e;
			background-image: url('/auth-bg/mobile-dark.jpg');
			background-size: cover;
			background-position: 60% 30%;
			color: #f2f4f4;
		}

		.org-shade {
			display: block;
			position: absolute;
			inset: 0;
			background-image: linear-gradient(
				in oklab 90deg,
				oklab(22.8% -0.004 -0.003 / 94%) 0%,
				oklab(22.8% -0.004 -0.003 / 55%) 55%,
				oklab(22.8% -0.004 -0.003 / 0%) 100%
			);
		}

		.org-band :global(.org-dialog-root) {
			display: block;
			position: absolute;
			right: 30px;
			bottom: -14px;
			width: 132px;
			height: 170px;
		}

		.org-handle {
			display: none;
		}

		/* Long titles wrap before Root (Paper E03 "Can’t add members right now"). */
		.org-band :global(.org-dialog-title) {
			max-width: calc(100% - 150px);
		}

		.org-band :global(.org-dialog-sub) {
			padding-top: 4px;
			color: #a9b0b3;
		}

		.org-body {
			gap: 20px;
			padding: 24px 28px 8px;
		}

		.org-actions {
			justify-content: flex-end;
			padding: 24px 28px 26px;
		}

		:global(.org-cancel),
		.org-go {
			flex: 0 0 auto;
			height: 48px;
		}
	}
</style>
