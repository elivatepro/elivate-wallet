<!--
	Invitation join (W-02). Paper "Authentication v2" 08 Invitation verification,
	09 Set password, 10 Invitation unavailable. No Root here: the auth pages
	in that set have none.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import { onMount } from 'svelte';
	import Check from '@lucide/svelte/icons/check';
	import Mail from '@lucide/svelte/icons/mail';
	import Unlink from '@lucide/svelte/icons/unlink';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import LockedField from '#lib/ui/auth/LockedField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
	import { MIN_PASSWORD } from '../credentials';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);
	let missingToken = $state(false);
	let claimForm: HTMLFormElement | undefined = $state();
	let tokenInput: HTMLInputElement | undefined = $state();

	const unavailable = $derived(data.mode === 'unavailable' || !!form?.unavailable || missingToken);
	const mismatch = $derived(form && 'mismatch' in form ? (form.message ?? '') : null);
	const sent = $derived(data.mode === 'verify' && !!form && 'sent' in form && form.sent);

	onMount(() => {
		if (data.mode !== 'claim' || form) return;
		// Read the link secret from the fragment, then drop it from the address
		// bar and history before anything else happens.
		const token = new URLSearchParams(location.hash.slice(1)).get('t');
		history.replaceState(history.state, '', location.pathname);
		if (!token || !claimForm || !tokenInput) {
			missingToken = true;
			return;
		}
		tokenInput.value = token;
		claimForm.requestSubmit();
	});

	const submitting = () => {
		busy = true;
		return async ({ update }: { update: (opts?: { reset?: boolean }) => Promise<void> }) => {
			await update({ reset: false });
			busy = false;
		};
	};

	const title = $derived(
		unavailable
			? 'Invitation unavailable'
			: sent
				? 'Check your inbox'
				: data.mode === 'password'
					? 'Choose a password'
					: data.mode === 'accept' || mismatch !== null
						? 'Accept your invitation'
						: data.mode === 'verify'
							? 'Confirm your email'
							: 'Opening your invitation'
	);
</script>

<svelte:head>
	<title>{title} · Elivate Wallet</title>
</svelte:head>

{#if unavailable}
	<AuthHeading
		icon={Unlink}
		eyebrow="Invitation"
		{title}
		lead="We couldn’t verify this invitation. Return to sign in or ask the person who invited you to share a new one."
	/>
	<PrimaryButton label="Back to sign in" href="/sign-in" />
{:else if mismatch}
	<!-- The link was forgotten server-side; the reload must not read a fragment. -->
	<AuthHeading eyebrow="Invitation" {title} />
	<FormAlert message={mismatch} />
	<SignOutLink label="Use another account" />
{:else if data.mode === 'claim'}
	<AuthHeading eyebrow="Invitation" {title} />
	<form method="POST" action="?/claim" bind:this={claimForm} hidden>
		<input type="hidden" name="token" bind:this={tokenInput} />
	</form>
	<noscript><p class="note">Turn on JavaScript to open this invitation.</p></noscript>
{:else if data.mode === 'verify' && sent}
	<AuthHeading
		icon={Mail}
		eyebrow="Invitation"
		{title}
		lead={`We sent a sign-in link to ${data.maskedEmail}.`}
	/>
	<AltLink label="Return to sign in" href="/sign-in" />
{:else if data.mode === 'verify'}
	<AuthHeading
		eyebrow="Invitation"
		{title}
		lead="This invitation is linked to the email address below."
	/>
	<form method="POST" action="?/verify" novalidate use:enhance={submitting}>
		{#if form?.message}<FormAlert message={form.message} />{/if}
		<LockedField id="invited-email" label="Invited email" value={data.maskedEmail} />
		<div class="actions">
			<PrimaryButton label="Verify email" {busy} />
			<AltLink label="Return to sign in" href="/sign-in" />
		</div>
	</form>
{:else if data.mode === 'password'}
	<AuthHeading eyebrow="Set password" {title} lead="Set a password for the verified email below." />
	<form method="POST" action="?/password" novalidate use:enhance={submitting}>
		{#if form?.message}<FormAlert message={form.message} />{/if}
		<div class="fields">
			<LockedField id="verified-email" label="Email" value={data.email} locked={false}>
				{#snippet trailing()}
					<span class="verified"
						><Check size={14} strokeWidth={2} aria-hidden="true" />Verified</span
					>
				{/snippet}
			</LockedField>
			<Field
				id="password"
				name="password"
				type="password"
				label="New password"
				placeholder="Create a password"
				autocomplete="new-password"
				minlength={MIN_PASSWORD}
				error={form?.error}
			/>
		</div>
		<PrimaryButton label="Set password" {busy} />
	</form>
{:else if data.mode === 'accept'}
	<AuthHeading eyebrow="Invitation" {title} />
	<form method="POST" action="?/accept" novalidate use:enhance={submitting}>
		{#if form?.message}<FormAlert message={form.message} />{/if}
		<input
			type="hidden"
			name="idempotencyKey"
			value={(form && 'idempotencyKey' in form && form.idempotencyKey) || data.idempotencyKey}
		/>
		<LockedField id="verified-email" label="Email" value={data.email} locked={false}>
			{#snippet trailing()}
				<span class="verified"><Check size={14} strokeWidth={2} aria-hidden="true" />Verified</span>
			{/snippet}
		</LockedField>
		<PrimaryButton label="Accept invitation" {busy} />
	</form>
	<SignOutLink label="Use another account" tight />
{/if}

<style>
	form,
	.fields,
	.actions {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	form {
		gap: 28px;
	}

	.verified {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		color: var(--color-success);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		letter-spacing: 0.14em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.note {
		color: var(--auth-body);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	@media (min-width: 1024px) {
		form {
			gap: 32px;
		}
	}
</style>
