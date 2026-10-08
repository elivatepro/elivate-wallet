<!-- Paper "Authentication v2" · 01/02/03 Sign in. -->
<script lang="ts">
	import { enhance } from '$app/forms';
	import { onMount } from 'svelte';
	import { purgeAllDeviceData } from '#lib/client/device-cache.js';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import type { PageProps } from './$types';

	let { form }: PageProps = $props();
	let busy = $state(false);

	// Nobody is signed in here, so no cached wallet data may remain on this
	// device (decision 36a: erased on sign-out).
	onMount(() => purgeAllDeviceData());
</script>

<svelte:head><title>Sign in · Elivate Wallet</title></svelte:head>

<AuthHeading eyebrow="Sign in" title="Welcome back" />

<form
	method="POST"
	novalidate
	use:enhance={() => {
		busy = true;
		return async ({ update }) => {
			await update({ reset: false });
			busy = false;
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
			placeholder="Enter your password"
			autocomplete="current-password"
			error={form?.errors?.password}
		/>
	</div>
	<div class="actions">
		<PrimaryButton label="Sign in" {busy} />
		<AltLink prompt="New to Elivate?" label="Start your network" href="/sign-up" />
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
