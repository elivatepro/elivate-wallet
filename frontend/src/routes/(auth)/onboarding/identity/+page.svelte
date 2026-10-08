<!--
	Wizard step 2 · identity. Paper "Onboarding — Invited member" 04 Verify NIN,
	05 Checking (busy state), 06 Not verified, 07 Leader review. The review
	request form has no Paper composition yet; it reuses the same frame.
	Owner decision 2026-10-08: reviewers are the President Team, World Team or
	Elivate admins, so the copy says "your leaders" (Paper says Team Leader).
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
	import NinField from '#lib/ui/onboarding/NinField.svelte';
	import SummaryCard from '#lib/ui/onboarding/SummaryCard.svelte';
	import WizardProgress from '#lib/ui/onboarding/WizardProgress.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);

	const failed = $derived(!!form && 'failed' in form && form.failed);
	const reviewing = $derived(data.mode === 'review' || (!!form && 'review' in form));
	const rejected = $derived(data.identity.review?.status === 'rejected');
	const errors = $derived<Record<string, string>>(
		(form && 'errors' in form && (form.errors as Record<string, string>)) || {}
	);
	const field = (name: string) =>
		form && name in form ? String((form as Record<string, unknown>)[name] ?? '') : '';

	useRoot(() =>
		data.mode === 'waiting'
			? 'onboard-waiting'
			: failed || reviewing
				? 'onboard-retry'
				: 'onboard-verifying'
	);

	const requested = $derived(
		data.identity.review
			? new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(
					new Date(data.identity.review.requestedAt)
				)
			: ''
	);

	const submitting = () => {
		busy = true;
		return async ({ update }: { update: (o?: { reset?: boolean }) => Promise<void> }) => {
			await update({ reset: false });
			busy = false;
		};
	};
</script>

<svelte:head><title>Verify your NIN · Elivate Wallet</title></svelte:head>

<WizardProgress step={2} backHref={data.mode === 'waiting' ? undefined : '/onboarding'} />

{#if data.mode === 'waiting'}
	<AuthHeading
		eyebrow="Step 2 · Under review"
		title="Your leader is reviewing it"
		lead="We’ve asked your leaders to check your NIN. We’ll email you once they decide."
	/>
	<SummaryCard
		rows={[
			{ label: 'NIN review', badge: pending },
			{ label: 'Requested', value: requested }
		]}
	/>
	{#snippet pending()}<span class="pill">Pending</span>{/snippet}
	<SignOutLink label="Sign out for now" />
{:else if reviewing}
	<AuthHeading
		eyebrow="Step 2 · Identity"
		title="Ask a leader to review"
		lead={rejected
			? 'Your last review wasn’t approved. Check your details and ask again.'
			: 'Enter your NIN and your name exactly as on your national ID.'}
	/>
	<form method="POST" action="?/review" novalidate use:enhance={submitting}>
		{#if form && 'message' in form && form.message}<FormAlert message={String(form.message)} />{/if}
		<input type="hidden" name="idempotencyKey" value={data.idempotencyKey} />
		<NinField value={field('nin')} error={errors.nin} />
		<Field
			id="givenName"
			name="givenName"
			label="First name"
			autocomplete="given-name"
			value={field('givenName')}
			error={errors.givenName}
			maxlength={80}
		/>
		<Field
			id="middleNames"
			name="middleNames"
			label="Middle name"
			autocomplete="additional-name"
			value={field('middleNames')}
			error={errors.middleNames}
			required={false}
		/>
		<Field
			id="surname"
			name="surname"
			label="Surname"
			autocomplete="family-name"
			value={field('surname')}
			error={errors.surname}
			maxlength={80}
		/>
		<PrimaryButton label="Ask for a review" {busy} disabled={!data.canReview} />
	</form>
	{#if data.identity.checksRemaining > 0}
		<AltLink label="Try the check again" href="/onboarding/identity" />
	{/if}
{:else}
	<AuthHeading
		eyebrow="Step 2 · Identity"
		tone={failed ? 'danger' : 'accent'}
		title={failed ? 'We couldn’t verify that NIN' : busy ? 'Checking your NIN' : 'Verify your NIN'}
		lead={failed
			? 'Check the number and try again. If it still doesn’t work, a leader can review it.'
			: busy
				? 'Hang tight, Root is matching your number with the national ID record.'
				: 'Root will confirm the name on your national ID. Once verified, it’s locked to your account.'}
	/>
	<form method="POST" action="?/verify" novalidate use:enhance={submitting}>
		{#if form && 'message' in form && form.message}<FormAlert message={String(form.message)} />{/if}
		<NinField
			value={field('nin')}
			error={form && 'error' in form ? String(form.error) : null}
			readonly={busy}
			autofocus
		/>
		<PrimaryButton label={busy ? 'Checking…' : failed ? 'Try again' : 'Verify NIN'} {busy} />
	</form>
	{#if data.identity.failedChecks > 0 || failed}
		<AltLink label="Ask my leaders to review" href="/onboarding/identity?review" />
	{/if}
{/if}

<style>
	form {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	.pill {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 4px 10px;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--color-warning) 16%, transparent);
		color: var(--color-warning);
		font-size: 13px;
		font-weight: var(--font-weight-medium);
	}

	.pill::before {
		content: '';
		width: 6px;
		height: 6px;
		border-radius: var(--radius-pill);
		background: currentColor;
	}
</style>
