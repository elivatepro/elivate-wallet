<!--
	Joining by team link (Blueprint 38). Paper "Team links v11" TL03/TL03d (sign
	up), TL05/TL05d (signed in) and TL04/TL04d (unavailable). No Root here, like
	the other auth pages.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import Mail from '@lucide/svelte/icons/mail';
	import Unlink from '@lucide/svelte/icons/unlink';
	import { invitedLine } from '#lib/team-links.js';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import LockedField from '#lib/ui/auth/LockedField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
	import Turnstile from '#lib/ui/auth/Turnstile.svelte';
	import { MIN_PASSWORD } from '../credentials';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);
	let turnstile: Turnstile | undefined = $state();
	let checkFailed = $state(false);

	const unavailable = $derived(data.mode === 'unavailable' || (!!form && 'unavailable' in form));
	const sent = $derived(!!form && 'sent' in form && form.sent);
	const lead = $derived(
		data.mode === 'unavailable' ? '' : `${invitedLine(data.team)} You’ll join as a Member.`
	);
	const title = $derived(
		unavailable
			? 'This link has stopped working'
			: sent
				? 'Check your inbox'
				: data.mode === 'unavailable'
					? ''
					: `Join ${data.team.officeName}`
	);

	const submitting = () => {
		busy = true;
		return async ({ update }: { update: (opts?: { reset?: boolean }) => Promise<void> }) => {
			await update({ reset: false });
			busy = false;
			// Each Turnstile token verifies once; get a fresh one for a retry.
			turnstile?.reset();
		};
	};
</script>

<svelte:head>
	<title>{title} · Elivate Wallet</title>
</svelte:head>

{#if unavailable}
	<AuthHeading
		icon={Unlink}
		eyebrow="Team invite"
		{title}
		lead="It may have expired, been used by as many people as allowed, or been turned off. Ask whoever shared it for a new one."
	/>
	<PrimaryButton label="Go to sign in" href="/sign-in" />
{:else if data.mode === 'signup' && sent}
	<AuthHeading
		icon={Mail}
		eyebrow="Team invite"
		{title}
		lead={`We sent a link to ${form && 'email' in form ? form.email : 'your email'}. Open it in this browser to join. If you already have an account, sign in instead.`}
	/>
	<AltLink prompt="Have an account?" label="Sign in to join" href="/sign-in" />
{:else if data.mode === 'signup'}
	<AuthHeading eyebrow="Team invite" {title} {lead} />
	<form method="POST" action="?/signup" novalidate use:enhance={submitting}>
		{#if form && 'message' in form && form.message}<FormAlert message={form.message} />{/if}
		<div class="fields">
			<Field
				id="email"
				name="email"
				type="email"
				label="Email"
				placeholder="you@example.com"
				autocomplete="email"
				value={form && 'email' in form ? (form.email ?? '') : ''}
				error={form && 'errors' in form ? form.errors?.email : undefined}
			/>
			<Field
				id="password"
				name="password"
				type="password"
				label="Create a password"
				placeholder="At least {MIN_PASSWORD} characters"
				autocomplete="new-password"
				minlength={MIN_PASSWORD}
				hint="We’ll email you a link to confirm it’s you."
				error={form && 'errors' in form ? form.errors?.password : undefined}
			/>
			<Turnstile
				bind:this={turnstile}
				bind:failed={checkFailed}
				siteKey={data.turnstileSiteKey}
				action="sign-up"
				retryLabel="create your account"
				theme={data.theme === 'system' ? 'auto' : data.theme}
			/>
		</div>
		<div class="actions">
			<PrimaryButton label="Create account" {busy} disabled={checkFailed} />
			<AltLink prompt="Have an account?" label="Sign in to join" href="/sign-in" />
		</div>
	</form>
{:else if data.mode === 'join'}
	<AuthHeading eyebrow="Team invite" {title} {lead} />
	<form method="POST" action="?/join" novalidate use:enhance={submitting}>
		{#if form && 'message' in form && form.message}<FormAlert message={form.message} />{/if}
		<input
			type="hidden"
			name="idempotencyKey"
			value={(form && 'idempotencyKey' in form && form.idempotencyKey) || data.idempotencyKey}
		/>
		<LockedField id="signed-in-email" label="Signed in as" value={data.email} />
		<PrimaryButton label={`Join ${data.team.networkName}`} {busy} />
	</form>
	<SignOutLink label="Not you? Sign out" next="/team-join" tight />
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

	@media (min-width: 1024px) {
		form {
			gap: 32px;
		}
	}
</style>
