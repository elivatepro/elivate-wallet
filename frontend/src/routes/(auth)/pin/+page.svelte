<!-- Paper "Authentication v2" · 12 Enter your PIN (four cells, Verify). -->
<script lang="ts">
	import { enhance } from '$app/forms';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
	import type { PageProps } from './$types';

	let { form }: PageProps = $props();
	let busy = $state(false);
</script>

<svelte:head><title>Enter your PIN · Elivate Wallet</title></svelte:head>

<AuthHeading
	eyebrow="Sign in"
	title="Enter your PIN"
	lead="Your 4-digit PIN, every time you sign in."
/>

<form
	method="POST"
	novalidate
	use:enhance={() => {
		busy = true;
		return async ({ update }) => {
			await update();
			busy = false;
		};
	}}
>
	{#key form}
		<PinField
			id="pin"
			name="pin"
			label="PIN"
			autocomplete="current-password"
			error={form?.error}
			autofocus
		/>
	{/key}
	<PrimaryButton label="Verify" {busy} />
</form>
<div class="links">
	<AltLink label="Forgot PIN?" href="/pin/forgot" />
	<SignOutLink />
</div>

<style>
	form {
		display: flex;
		flex-direction: column;
		gap: 28px;
	}

	.links {
		display: flex;
		flex-wrap: wrap;
		justify-content: center;
		gap: 4px 20px;
		margin-top: -8px;
	}
</style>
