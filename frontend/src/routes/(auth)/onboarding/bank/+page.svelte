<!--
	Wizard step 4 · payout account. Paper "Onboarding — Invited member" 11
	(matched), 12 (name mismatch) and "App — Screens v3" Y01 (identity check
	pending). Nigerian NUBAN only (W-17).
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import NameCheck from '#lib/ui/onboarding/NameCheck.svelte';
	import WizardProgress from '#lib/ui/onboarding/WizardProgress.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);

	const lookup = $derived(form && 'lookup' in form ? form.lookup : null);
	const mismatch = $derived(lookup?.nameMatch === 'mismatched');
	const needPin = $derived(!!form && 'needPin' in form && form.needPin);
	const errors = $derived<Record<string, string>>(
		(form && 'errors' in form && (form.errors as Record<string, string>)) || {}
	);
	const bankCode = $derived(form && 'bankCode' in form ? String(form.bankCode) : '');
	const accountNumber = $derived(form && 'accountNumber' in form ? String(form.accountNumber) : '');
	useRoot(() => (mismatch ? 'onboard-stop' : 'onboard-bank'));

	const submitting = () => {
		busy = true;
		return async ({ update }: { update: (o?: { reset?: boolean }) => Promise<void> }) => {
			await update({ reset: false });
			busy = false;
		};
	};
</script>

<svelte:head><title>Payout account · Elivate Wallet</title></svelte:head>

<WizardProgress step={4} backHref="/onboarding/profile" />
<AuthHeading
	eyebrow="Step 4 · Payout account"
	tone={mismatch ? 'danger' : 'accent'}
	title={mismatch ? 'Name doesn’t match' : 'Where should payouts go?'}
	lead={mismatch
		? 'For your safety, payouts can only go to an account that matches your verified name.'
		: 'Add a Naira account in your own name.'}
/>

{#if data.banksUnavailable}
	<FormAlert message="We couldn’t load the bank list right now. Try again shortly." />
{/if}

<form method="POST" action="?/lookup" novalidate use:enhance={submitting}>
	{#if form && 'message' in form && form.message && !lookup}<FormAlert
			message={String(form.message)}
		/>{/if}
	<input type="hidden" name="idempotencyKey" value={data.idempotencyKey} />
	<div class="field">
		<label for="bankCode">Bank</label>
		<select
			id="bankCode"
			name="bankCode"
			disabled={!!lookup}
			aria-invalid={errors.bankCode ? 'true' : undefined}
		>
			<option value="" disabled selected={!bankCode}>Choose your bank</option>
			{#each data.banks as bank (bank.code)}
				<option value={bank.code} selected={bank.code === bankCode}>{bank.name}</option>
			{/each}
		</select>
		{#if errors.bankCode}<p class="error">{errors.bankCode}</p>{/if}
	</div>
	<Field
		id="accountNumber"
		name="accountNumber"
		label="Account number"
		placeholder="0123456789"
		autocomplete="off"
		maxlength={10}
		value={accountNumber}
		error={errors.accountNumber}
	/>
	{#if needPin}
		<PinField
			id="pin"
			name="pin"
			label="Enter your PIN to check the account"
			error={errors.pin}
			autofocus
		/>
	{/if}
	{#if !lookup}
		<PrimaryButton label="Check account" {busy} disabled={data.banks.length === 0} />
	{/if}
</form>

{#if lookup}
	<NameCheck accountName={lookup.accountName} match={lookup.nameMatch} legalName={data.legalName} />
	{#if mismatch}
		<PrimaryButton label="Use a different account" href="/onboarding/bank" />
	{:else}
		<form method="POST" action="?/confirm" use:enhance={submitting}>
			<input type="hidden" name="lookupId" value={lookup.lookupId} />
			<input
				type="hidden"
				name="idempotencyKey"
				value={form && 'confirmKey' in form ? form.confirmKey : ''}
			/>
			<PrimaryButton label={lookup.nameMatch === 'matched' ? 'Save account' : 'Continue'} {busy} />
		</form>
		<AltLink label="Use a different account" href="/onboarding/bank" />
	{/if}
{/if}

<style>
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

	select:disabled {
		opacity: 0.8;
	}

	.error {
		color: var(--color-danger);
		font-size: var(--text-14);
	}
</style>
