<!--
	Add a payout account (W-17), the in-app twin of the wizard bank step
	(Paper "Onboarding — Invited member" 11/12, App v3 Y01): bank + 10-digit
	number → lookup (PIN when step-up is needed) → resolved name with the NIN
	check → explicit Save. A mismatch cannot be saved. The number lives only in
	the input and the POST body; it is never cached, logged or put in a URL.
	`?replace=<account id>` replaces an active account (W-17, Blueprint 10):
	same lookup plus a reason on save. That variant is not drawn in Paper yet
	(waiting on owner approval); it reuses this layout.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import { AppRoutes, BanksView } from '#lib/contract/app.js';
	import { Lookup, PayoutAccount, type Bank } from '#lib/contract/payout.js';
	import type { ApiFailure } from '#lib/contract/errors.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import {
		cleanAccountNumber,
		isRefusal,
		lookupFieldError,
		payoutMessage,
		pinProblem
	} from '#lib/payout.js';
	import { ACCOUNT_NUMBER_PATTERN } from '#lib/contract/payout.js';
	import { UUID_PATTERN } from '#lib/contract/common.js';
	import { takeReplaceIntent, type ReplaceIntent } from '#lib/client/replace-intent.js';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import NameCheck from '#lib/ui/onboarding/NameCheck.svelte';

	const shell = getContext<Shell>('shell');

	let banks = $state<ReadonlyArray<Bank> | null>(null);
	let banksUnavailable = $state(false);
	let bankCode = $state('');
	let lookup = $state<Lookup | null>(null);
	let needPin = $state(false);
	let busy = $state(false);
	let errors = $state<{ bankCode?: string; accountNumber?: string; pin?: string; reason?: string }>(
		{}
	);
	let reason = $state('');
	/**
	 * Set when a replacement save's outcome is unknown: the reason stays as
	 * sent so the retry replays the same request with the same key (W-00).
	 */
	let reasonLocked = $state(false);
	let formError = $state<string | null>(null);
	/** Bumped to remount the inputs (clears the number and PIN). */
	let formId = $state(0);
	/** Bumped after a PIN failure: the PIN is never kept after a failed try. */
	let pinTry = $state(0);

	let lookupKey = newKey();
	let lookupFor = '';
	let confirmKey = newKey();

	const mismatch = $derived(lookup?.nameMatch === 'mismatched');
	/** The account being replaced, when this is a replacement (never a number, only its id). */
	const replaces = $derived.by(() => {
		const id = page.url.searchParams.get('replace');
		return id && UUID_PATTERN.test(id) ? id.toLowerCase() : null;
	});
	/** Reason and PIN from the Z05 dialog (memory only, read once). */
	let intent = $state<ReplaceIntent | null>(null);
	$effect(() => {
		if (replaces && !intent) intent = takeReplaceIntent(replaces);
		if (intent && !reason) reason = intent.reason;
	});

	async function loadBanks() {
		const exit = await Effect.runPromiseExit(getJson(AppRoutes.payoutBanks.path, BanksView));
		if (Exit.isSuccess(exit)) {
			banks = exit.value.banks;
			banksUnavailable = false;
		} else {
			banks = [];
			banksUnavailable = true;
		}
	}

	$effect(() => {
		if (shell.state.kind === 'ready' && !banks) void loadBanks();
	});

	const failureOf = <A,>(exit: Exit.Exit<A, ApiFailure>) =>
		Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) : undefined;

	/** PIN problems stay on the PIN field; true when handled. */
	function handlePin(failure: ApiFailure | undefined, ask: string): boolean {
		const problem = pinProblem(failure, ask);
		if (problem?.kind === 'locked') {
			window.location.assign('/pin/locked');
			return true;
		}
		if (problem) {
			const asked = failure?._tag === 'BackendError' && failure.code === 'step_up_required';
			// First ask: the field's label says it all; after a typed PIN, say why.
			errors = { pin: asked && !needPin ? undefined : problem.message };
			needPin = true;
			pinTry += 1;
			return true;
		}
		return false;
	}

	async function check(event: SubmitEvent) {
		event.preventDefault();
		if (shell.state.kind !== 'ready' || !shell.canAct) return;
		const data = new FormData(event.currentTarget as HTMLFormElement);
		const accountNumber = cleanAccountNumber(String(data.get('accountNumber') ?? ''));
		// The Z05 dialog's PIN opens the step-up for the first lookup; used once.
		const pin = String(data.get('pin') ?? '') || intent?.pin || undefined;
		if (intent?.pin) intent = { ...intent, pin: undefined };
		const next: typeof errors = {};
		if (!bankCode) next.bankCode = 'Choose your bank.';
		if (!ACCOUNT_NUMBER_PATTERN.test(accountNumber))
			next.accountNumber = 'Enter the 10-digit account number.';
		if (pin !== undefined && !/^[0-9]{4}$/.test(pin)) next.pin = 'Enter your 4-digit PIN.';
		errors = next;
		formError = null;
		if (Object.keys(next).length) return;

		// Same request, same key (an unknown outcome is retried with it, W-00).
		const target = `${bankCode}:${accountNumber}`;
		if (target !== lookupFor) {
			lookupFor = target;
			lookupKey = newKey();
		}
		busy = true;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				AppRoutes.payoutLookup.path,
				'POST',
				{
					bankCode,
					accountNumber,
					...(replaces ? { replacesPayoutAccountId: replaces } : {}),
					...(pin ? { pin } : {}),
					idempotencyKey: lookupKey
				},
				shell.state.view.workspace.membershipId,
				Lookup
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			lookup = exit.value;
			lookupFor = '';
			confirmKey = newKey();
			reasonLocked = false;
			needPin = false;
			errors = {};
			return;
		}
		const failure = failureOf(exit);
		if (handlePin(failure, 'Enter your PIN to check the account.')) return;
		if (isRefusal(failure)) lookupFor = '';
		const field = lookupFieldError(failure);
		if (field) errors = { [field.field]: field.message };
		else formError = payoutMessage(failure, 'lookup');
	}

	async function save(event: SubmitEvent) {
		event.preventDefault();
		if (!lookup || mismatch || shell.state.kind !== 'ready' || !shell.canAct) return;
		const data = new FormData(event.currentTarget as HTMLFormElement);
		const pin = String(data.get('pin') ?? '') || undefined;
		if (pin !== undefined && !/^[0-9]{4}$/.test(pin)) {
			errors = { pin: 'Enter your 4-digit PIN.' };
			return;
		}
		// Same rule as the backend: 3–500 characters after trimming (W-17 Q8).
		const why = reason.trim();
		if (replaces && ([...why].length < 3 || [...why].length > 500)) {
			errors = { reason: 'Say why you’re replacing it (3–500 characters).' };
			return;
		}
		errors = {};
		formError = null;
		busy = true;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				AppRoutes.payoutConfirm.path,
				'POST',
				{
					lookupId: lookup.lookupId,
					...(replaces ? { reason: why } : {}),
					...(pin ? { pin } : {}),
					idempotencyKey: confirmKey
				},
				shell.state.view.workspace.membershipId,
				PayoutAccount
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			await goto('/app/payout-accounts');
			return;
		}
		const failure = failureOf(exit);
		if (handlePin(failure, 'Enter your PIN to save the account.')) return;
		if (failure?._tag === 'BackendError' && failure.code === 'payout_lookup_expired') {
			startOver();
			formError = payoutMessage(failure, 'confirm');
			return;
		}
		if (isRefusal(failure)) {
			confirmKey = newKey();
			reasonLocked = false;
		} else {
			reasonLocked = true;
		}
		formError = payoutMessage(failure, 'confirm');
	}

	function startOver() {
		lookup = null;
		needPin = false;
		errors = {};
		formError = null;
		lookupFor = '';
		formId += 1;
	}
</script>

<svelte:head
	><title>{replaces ? 'Replace bank account' : 'Add bank account'} · Elivate Wallet</title
	></svelte:head
>

<div class="page">
	<a class="back" href="/app/payout-accounts"
		><ChevronLeft size={18} strokeWidth={2} aria-hidden="true" />Payout accounts</a
	>
	<section class="card" aria-labelledby="add-heading">
		<header>
			<h1 id="add-heading">
				{mismatch ? 'Name doesn’t match' : replaces ? 'Replace bank account' : 'Add bank account'}
			</h1>
			<p>
				{mismatch
					? 'Payouts can only go to an account in your verified name.'
					: replaces
						? 'The old account stays in your history. The new one can receive withdrawals 24 hours after you save it.'
						: 'A Naira account in your own name.'}
			</p>
		</header>

		{#if banksUnavailable}
			<FormAlert message="We couldn’t load the bank list right now. Try again shortly." />
		{/if}
		{#if formError}<FormAlert message={formError} />{/if}

		{#key formId}
			{#if !lookup}
				<form onsubmit={check} novalidate>
					<div class="field">
						<label for="bankCode">Bank</label>
						<select
							id="bankCode"
							bind:value={bankCode}
							aria-invalid={errors.bankCode ? 'true' : undefined}
							aria-describedby={errors.bankCode ? 'bankCode-error' : undefined}
						>
							<option value="" disabled>Choose your bank</option>
							{#each banks ?? [] as bank (bank.code)}
								<option value={bank.code}>{bank.name}</option>
							{/each}
						</select>
						{#if errors.bankCode}<p class="error" id="bankCode-error">{errors.bankCode}</p>{/if}
					</div>
					<Field
						id="accountNumber"
						name="accountNumber"
						label="Account number"
						placeholder="0123456789"
						autocomplete="off"
						maxlength={10}
						error={errors.accountNumber}
					/>
					{#if needPin}
						{#key pinTry}
							<PinField
								id="pin"
								name="pin"
								label="Enter your PIN to check the account"
								error={errors.pin}
								autofocus
							/>
						{/key}
					{/if}
					<PrimaryButton
						label="Check account"
						{busy}
						disabled={!banks || banks.length === 0 || !shell.canAct}
					/>
				</form>
			{:else}
				<NameCheck accountName={lookup.accountName} match={lookup.nameMatch} legalName={null} />
				{#if !mismatch}
					<form onsubmit={save} novalidate>
						{#if replaces && !intent}
							<!-- Only when the Z05 dialog's reason is missing (e.g. after a reload). -->
							<div class="field">
								<label for="reason">Why are you replacing it?</label>
								<textarea
									id="reason"
									name="reason"
									rows="3"
									maxlength="500"
									readonly={reasonLocked}
									bind:value={reason}
									aria-invalid={errors.reason ? 'true' : undefined}
									aria-describedby={errors.reason ? 'reason-error' : undefined}></textarea>
								{#if errors.reason}<p class="error" id="reason-error">{errors.reason}</p>{/if}
							</div>
						{/if}
						{#if needPin}
							{#key pinTry}
								<PinField
									id="pin"
									name="pin"
									label="Enter your PIN to save the account"
									error={errors.pin}
									autofocus
								/>
							{/key}
						{/if}
						<PrimaryButton
							label={replaces
								? 'Replace account'
								: lookup.nameMatch === 'matched'
									? 'Save account'
									: 'Continue'}
							{busy}
							disabled={!shell.canAct}
						/>
					</form>
				{/if}
				<button type="button" class="ghost" onclick={startOver}>Use a different account</button>
			{/if}
		{/key}
	</section>
</div>

<style>
	.page {
		display: flex;
		flex-direction: column;
		gap: 16px;
		width: 100%;
		max-width: 560px;
	}

	.back {
		display: inline-flex;
		align-items: center;
		align-self: flex-start;
		gap: 4px;
		min-height: var(--hit-min);
		color: var(--color-muted);
		font-size: var(--text-14);
		text-decoration: none;
	}

	.card {
		display: flex;
		flex-direction: column;
		gap: 20px;
		padding: 24px 20px;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 18px;
		background: var(--color-surface);
	}

	header {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	h1 {
		font-size: var(--text-24);
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: var(--leading-32);
	}

	header p {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	form,
	.field {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	.field {
		gap: 8px;
	}

	label {
		color: var(--auth-label);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	textarea {
		padding: 14px 16px;
		border-radius: var(--radius-12);
		border: 1px solid var(--auth-field-border);
		background: var(--auth-field-bg);
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		resize: vertical;
	}

	textarea:focus {
		outline: none;
		border-color: var(--color-accent);
	}

	textarea[aria-invalid='true'] {
		border-color: var(--color-danger);
	}

	select {
		height: 52px;
		padding: 0 16px;
		border-radius: var(--radius-12);
		border: 1px solid var(--auth-field-border);
		background: var(--auth-field-bg);
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
	}

	select:focus {
		outline: none;
		border-color: var(--color-accent);
	}

	select[aria-invalid='true'] {
		border-color: var(--color-danger);
	}

	.error {
		color: var(--color-danger);
		font-size: var(--text-14);
	}

	.ghost {
		min-height: 48px;
		padding: 0 22px;
		border: 1px solid color-mix(in oklab, var(--color-text) 20%, transparent);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	@media (min-width: 1024px) {
		.card {
			padding: 32px;
			border-radius: var(--radius-16);
		}
	}
</style>
