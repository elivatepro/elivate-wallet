<!--
	Unknown-outcome screen, Paper "App — Screens v1" B16 (mobile) / B16d
	(desktop): "Checking your request". Bound to a CommandAttempt; shows the
	attempt's non-secret summary and short label, never a new key.

	The resolved variants (it went through / it didn't go through / still
	checking) are not drawn in Paper yet: they reuse this layout with plain copy
	and are listed as waiting on Paper approval (Blueprint 08).
-->
<script lang="ts">
	import type { AttemptControls } from '#lib/client/command-attempt.svelte.js';
	import { attemptLabel } from '#lib/recovery.js';
	import { pinProblem } from '#lib/payout.js';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import CheckingPanel from './CheckingPanel.svelte';

	let {
		attempt,
		noun = 'request',
		backHref = '/app',
		backLabel = 'Back to Home',
		onResolved
	}: {
		attempt: AttemptControls;
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
	/**
	 * "Send again" asked for the PIN while recovering: the same saved attempt is
	 * re-sent with it from here, never from the editable form (F-03).
	 */
	const needsPin = $derived(!!attempt.recovering && !!attempt.awaitingPin);
	const pinMessage = $derived.by(() => {
		const problem = s.kind === 'failed' ? pinProblem(s.failure) : null;
		return problem?.kind === 'pin' ? problem.message : null;
	});
	let pinKey = $state(0);
	async function resendWithPin(event: SubmitEvent) {
		event.preventDefault();
		const pin = String(new FormData(event.currentTarget as HTMLFormElement).get('pin') ?? '');
		await attempt.resend(pin ? { pin } : {});
		const next = attempt.state;
		if (next.kind === 'failed' && pinProblem(next.failure)?.kind === 'locked') {
			window.location.assign('/pin/locked');
		}
		pinKey++;
	}

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
				return needsPin
					? `Enter your PIN to send ${what} again. It can only go through once.`
					: `We’re confirming ${what}. Don’t send it again.`;
		}
	});

	function finish() {
		attempt.reset();
		onResolved?.();
	}
</script>

<CheckingPanel
	{title}
	{lead}
	{busy}
	footnote={pending ? `Attempt ${attemptLabel(pending.key)}` : null}
>
	{#if needsPin}
		<form id="outcome-pin" class="pin" onsubmit={resendWithPin} novalidate>
			{#key pinKey}
				<PinField id="outcome-pin-field" name="pin" label="Your PIN" error={pinMessage} />
			{/key}
		</form>
	{:else if attempt.lastRefusal?._tag === 'BackendError'}
		<p class="refusal" role="alert">{attempt.lastRefusal.message}</p>
	{/if}
	{#snippet actions()}
		{#if needsPin}
			<button type="submit" form="outcome-pin" class="primary" disabled={busy}>Send again</button>
		{:else if resolution?.kind === 'not_committed' && resolution.canResend}
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
	{/snippet}
</CheckingPanel>

<style>
	.pin {
		width: 100%;
	}

	.refusal {
		color: var(--color-danger);
		font-size: var(--text-14);
		text-align: center;
	}
</style>
