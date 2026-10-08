<!-- Paper "Authentication v2" · 04 Start your network (founder entry, W-01). -->
<script lang="ts">
	import { enhance } from '$app/forms';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import Turnstile from '#lib/ui/auth/Turnstile.svelte';
	import { MIN_PASSWORD } from '../credentials';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);
	let turnstile: Turnstile | undefined = $state();
	let checkFailed = $state(false);
</script>

<svelte:head><title>Start your network · Elivate Wallet</title></svelte:head>

<AuthHeading eyebrow="Create account" title="Start your network" />

<form
	method="POST"
	novalidate
	use:enhance={() => {
		busy = true;
		return async ({ update }) => {
			await update({ reset: false });
			busy = false;
			// Each Turnstile token verifies once; get a fresh one for a retry.
			turnstile?.reset();
		};
	}}
>
	{#if form?.message}<FormAlert message={form.message} />{/if}
	<div class="fields">
		<Field
			id="email"
			name="email"
			type="email"
			label="Email address"
			placeholder="you@example.com"
			autocomplete="email"
			value={form?.email ?? ''}
			error={form?.errors?.email}
		/>
		<Field
			id="password"
			name="password"
			type="password"
			label="Password"
			placeholder="Create a password"
			autocomplete="new-password"
			minlength={MIN_PASSWORD}
			hint={`At least ${MIN_PASSWORD} characters.`}
			error={form?.errors?.password}
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
		<AltLink prompt="Already with Elivate?" label="Sign in" href="/sign-in" />
	</div>
</form>

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
