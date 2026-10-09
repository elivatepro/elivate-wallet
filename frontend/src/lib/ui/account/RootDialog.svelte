<!--
	Root dialog, Paper "App — Screens v4" Z04–Z07 (owner approved 2026-10-08).
	Desktop: 520 px modal, felt header (150 px) with title, one line and Root
	bottom-right. Mobile: bottom sheet (28 px top radius, grabber) with Root
	peeking over its top edge. Optional reason (one line, 3–500) and PIN
	cells; Cancel + confirm (coral, or the soft danger pill). Bits UI Dialog:
	focus is trapped and returns to the trigger. The PIN is cleared on every
	open and every failure (the field remounts).
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import { Dialog } from 'bits-ui';
	import RootImage from '#lib/ui/RootImage.svelte';
	import type { RootPose } from '#lib/ui/root.svelte.js';

	let {
		open = $bindable(false),
		pose,
		title,
		summary,
		confirmLabel,
		cancelLabel = 'Cancel',
		tone = 'accent',
		needsReason = false,
		needsPin = false,
		reasonPlaceholder = '',
		busy = false,
		error = null,
		reasonError = null,
		pinError = null,
		pinTry = 0,
		fields,
		onConfirm
	}: {
		open?: boolean;
		pose: RootPose;
		title: string;
		summary?: string;
		confirmLabel: string;
		cancelLabel?: string;
		tone?: 'accent' | 'danger';
		needsReason?: boolean;
		needsPin?: boolean;
		reasonPlaceholder?: string;
		busy?: boolean;
		error?: string | null;
		reasonError?: string | null;
		pinError?: string | null;
		/** Bump to clear the PIN cells (after a failed try). */
		pinTry?: number;
		/** Extra fields (Z04 profile). */
		fields?: Snippet;
		onConfirm: (input: { reason: string; pin: string | undefined; form: FormData }) => void;
	} = $props();

	let reason = $state('');
	let localReasonError = $state<string | null>(null);
	let pin = $state('');
	let pinFocused = $state(false);

	$effect(() => {
		if (open) {
			localReasonError = null;
			pin = '';
		}
	});
	$effect(() => {
		void pinTry;
		pin = '';
	});

	const onPin = (event: Event) => {
		const target = event.currentTarget as HTMLInputElement;
		pin = target.value.replace(/[^0-9]/g, '').slice(0, 4);
		target.value = pin;
	};

	function submit(event: SubmitEvent) {
		event.preventDefault();
		const form = new FormData(event.currentTarget as HTMLFormElement);
		const trimmed = reason.trim();
		if (needsReason && ([...trimmed].length < 3 || [...trimmed].length > 500)) {
			localReasonError = 'Give a reason (3–500 characters).';
			return;
		}
		localReasonError = null;
		onConfirm({ reason: trimmed, pin: needsPin && pin ? pin : undefined, form });
	}

	const shownReasonError = $derived(localReasonError ?? reasonError);
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="rd-scrim" />
		<Dialog.Content class="rd-panel" aria-describedby={summary ? 'rd-summary' : undefined}>
			<div class="rd-peek" aria-hidden="true">
				<RootImage {pose} class="rd-peek-root" sizes="112px" />
			</div>
			<form onsubmit={submit} novalidate>
				<div class="rd-header">
					<div class="rd-shade" aria-hidden="true"></div>
					<RootImage {pose} class="rd-root" sizes="128px" />
					<span class="rd-grabber" aria-hidden="true"></span>
					<div class="rd-heading">
						<Dialog.Title class="rd-title">{title}</Dialog.Title>
						{#if summary}<p class="rd-summary" id="rd-summary">{summary}</p>{/if}
					</div>
				</div>
				<div class="rd-fields">
					{#if error}<p class="rd-error" role="alert">{error}</p>{/if}
					{#if fields}{@render fields()}{/if}
					{#if needsReason}
						<div class="rd-field">
							<label class="rd-label" for="rd-reason">Reason</label>
							<input
								id="rd-reason"
								class="rd-input"
								type="text"
								maxlength="500"
								autocomplete="off"
								placeholder={reasonPlaceholder}
								bind:value={reason}
								aria-invalid={shownReasonError ? 'true' : undefined}
								aria-describedby={shownReasonError ? 'rd-reason-error' : undefined}
							/>
							{#if shownReasonError}<p class="rd-field-error" id="rd-reason-error">
									{shownReasonError}
								</p>{/if}
						</div>
					{/if}
					{#if needsPin && open}
						<div class="rd-field">
							<label class="rd-label" for="rd-pin">Your PIN</label>
							<div class="rd-pin">
								<input
									id="rd-pin"
									name="pin"
									type="password"
									inputmode="numeric"
									pattern="[0-9]{4}"
									maxlength="4"
									autocomplete="off"
									value={pin}
									oninput={onPin}
									onfocus={() => (pinFocused = true)}
									onblur={() => (pinFocused = false)}
									aria-invalid={pinError ? 'true' : undefined}
									aria-describedby={pinError ? 'rd-pin-error' : undefined}
								/>
								<div class="rd-cells" aria-hidden="true">
									{#each [0, 1, 2, 3] as index (index)}
										<div
											class="rd-cell"
											class:active={pinFocused &&
												(index === pin.length || (index === 3 && pin.length === 4))}
											class:invalid={!!pinError}
										>
											{#if index < pin.length}•{/if}
										</div>
									{/each}
								</div>
							</div>
							{#if pinError}<p class="rd-field-error" id="rd-pin-error">{pinError}</p>{/if}
						</div>
					{/if}
				</div>
				<div class="rd-actions">
					<Dialog.Close class="rd-cancel" type="button">{cancelLabel}</Dialog.Close>
					<button
						class="rd-go"
						data-tone={tone}
						type="submit"
						disabled={busy}
						aria-busy={busy ? 'true' : undefined}>{confirmLabel}</button
					>
				</div>
			</form>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.rd-scrim) {
		position: fixed;
		inset: 0;
		z-index: 50;
		background: #08090a9e;
	}

	/* Mobile: bottom sheet. */
	:global(.rd-panel) {
		position: fixed;
		left: 0;
		right: 0;
		bottom: 0;
		z-index: 51;
		max-height: calc(100dvh - 120px);
		border-top: 1px solid #343a3c;
		border-radius: 28px 28px 0 0;
		background: #1a1d1e;
		color: var(--color-text);
	}

	:global([data-theme='light']) :global(.rd-panel) {
		border-top-color: var(--color-border);
		background: var(--color-surface);
	}

	form {
		display: flex;
		flex-direction: column;
		gap: 16px;
		max-height: inherit;
		overflow-y: auto;
		padding: 10px 20px calc(28px + env(safe-area-inset-bottom));
	}

	.rd-peek {
		position: absolute;
		right: 28px;
		bottom: calc(100% - 16px);
		width: 112px;
		height: 150px;
		pointer-events: none;
	}

	.rd-peek :global(.rd-peek-root) {
		width: 100%;
		height: 100%;
	}

	.rd-header {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.rd-shade,
	.rd-header :global(.rd-root) {
		display: none;
	}

	.rd-grabber {
		align-self: center;
		width: 40px;
		height: 5px;
		border-radius: var(--radius-pill);
		background: #4a5153;
	}

	.rd-heading {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding-top: 6px;
	}

	:global(.rd-title) {
		color: var(--color-text);
		font-size: var(--text-24);
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.01em;
		line-height: 30px;
	}

	.rd-summary {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.rd-fields {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.rd-error {
		padding: 10px 14px;
		border-radius: var(--radius-12);
		background: color-mix(in oklab, var(--color-danger) 12%, transparent);
		color: var(--color-text);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.rd-field {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.rd-label {
		color: #d5dadb;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	:global([data-theme='light']) .rd-label {
		color: var(--color-text);
	}

	.rd-input {
		height: 48px;
		padding: 0 14px;
		border: 1px solid #2a2f31;
		border-radius: 14px;
		background: #141718;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		line-height: var(--leading-20);
	}

	.rd-input:focus {
		outline: none;
		border-color: var(--color-accent);
	}

	.rd-input[aria-invalid='true'] {
		border-color: var(--color-danger);
	}

	.rd-pin {
		position: relative;
	}

	.rd-pin input {
		position: absolute;
		inset: 0;
		z-index: 1;
		width: 100%;
		height: 56px;
		opacity: 0;
		cursor: text;
	}

	.rd-cells {
		display: flex;
		gap: 8px;
	}

	.rd-cell {
		display: flex;
		flex: 1 1 0%;
		align-items: center;
		justify-content: center;
		height: 56px;
		border: 1px solid #2a2f31;
		border-radius: var(--radius-12);
		background: #141718;
		color: var(--color-text);
		font-size: 30px;
		font-weight: var(--font-weight-semibold);
		line-height: 30px;
	}

	:global([data-theme='light']) .rd-cell,
	:global([data-theme='light']) .rd-input {
		border-color: var(--color-border);
		background: var(--color-raised);
	}

	.rd-cell.active {
		border-color: var(--color-accent);
		box-shadow: #ff7f4f33 0px 0px 0px 3px;
	}

	.rd-cell.invalid {
		border-color: var(--color-danger);
	}

	.rd-field-error {
		color: var(--color-danger);
		font-size: 13px;
		line-height: 18px;
	}

	.rd-actions {
		display: flex;
		gap: 12px;
		padding-top: 8px;
	}

	:global(.rd-cancel),
	.rd-go {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 52px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: 15px;
		line-height: 18px;
		cursor: pointer;
	}

	:global(.rd-cancel) {
		flex: 1 1 0%;
		border: 1px solid #343a3c;
		background: transparent;
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	:global([data-theme='light']) :global(.rd-cancel) {
		border-color: var(--color-border);
	}

	.rd-go {
		flex: 1.4 1 0%;
		border: 0;
		background-image: linear-gradient(
			in oklab 135deg,
			oklab(76.9% 0.087 0.084) 0%,
			oklab(71.1% 0.113 0.097) 55%,
			oklab(66.2% 0.12 0.099) 100%
		);
		box-shadow:
			#ffffff59 0px 1px 0px inset,
			#ff7f4f99 0px 10px 28px -10px;
		color: #14100e;
		font-weight: var(--font-weight-semibold);
	}

	.rd-go[data-tone='danger'] {
		background: #3a1f1f;
		box-shadow: none;
		color: var(--color-danger);
	}

	:global([data-theme='light']) .rd-go[data-tone='danger'] {
		background: color-mix(in oklab, var(--color-danger) 12%, transparent);
	}

	.rd-go:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	/* Desktop: 520 px modal with the felt header. */
	@media (min-width: 1024px) {
		:global(.rd-panel) {
			top: 50%;
			left: 50%;
			right: auto;
			bottom: auto;
			width: 520px;
			max-height: calc(100dvh - 64px);
			overflow: clip;
			transform: translate(-50%, -50%);
			border: 1px solid #343a3c;
			border-radius: var(--radius-24);
			box-shadow: #00000080 0px 30px 80px;
		}

		.rd-peek,
		.rd-grabber {
			display: none;
		}

		form {
			gap: 0;
			padding: 0;
		}

		.rd-header {
			justify-content: flex-end;
			flex-shrink: 0;
			height: 150px;
			padding: 24px 28px;
			overflow: clip;
			background-color: #1a1d1e;
			background-image: url('/auth-bg/mobile-dark.jpg');
			background-size: cover;
			background-position: 60% 30%;
		}

		.rd-shade {
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

		.rd-header :global(.rd-root) {
			display: block;
			position: absolute;
			right: 36px;
			bottom: -14px;
			width: 128px;
			height: 168px;
		}

		.rd-heading {
			gap: 0;
			padding-top: 0;
		}

		:global(.rd-title) {
			color: #f2f4f4;
		}

		.rd-summary {
			padding-top: 4px;
			color: #a9b0b3;
		}

		.rd-fields {
			gap: 20px;
			padding: 24px 28px 8px;
		}

		.rd-fields:empty {
			display: none;
		}

		.rd-actions {
			justify-content: flex-end;
			padding: 24px 28px 26px;
		}

		:global(.rd-cancel),
		.rd-go {
			flex: 0 0 auto;
			height: 48px;
			padding: 0 22px;
		}
	}
</style>
