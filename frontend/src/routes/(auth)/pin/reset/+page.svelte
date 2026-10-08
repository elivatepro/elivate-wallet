<!-- New PIN after the emailed reset link. Built from the "Enter your PIN" composition. -->
<script lang="ts">
	import { enhance } from '$app/forms';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import type { PageProps } from './$types';

	let { form }: PageProps = $props();
	let busy = $state(false);
</script>

<svelte:head><title>Choose a new PIN · Elivate Wallet</title></svelte:head>

<AuthHeading
	eyebrow="Reset PIN"
	title="Choose a new PIN"
	lead="Every device will ask for the new PIN."
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
	{#if form && 'message' in form && form.message}
		<FormAlert message={form.message} />
		<AltLink label="Request a new link" href="/pin/forgot" />
	{/if}
	<div class="fields">
		<PinField
			id="pin"
			name="pin"
			label="New PIN"
			autocomplete="new-password"
			error={form && 'errors' in form ? form.errors?.pin : null}
			autofocus
		/>
		<PinField
			id="pinConfirm"
			name="pinConfirm"
			label="Repeat new PIN"
			autocomplete="new-password"
			error={form && 'errors' in form ? form.errors?.pinConfirm : null}
		/>
	</div>
	<PrimaryButton label="Save new PIN" {busy} />
</form>

<style>
	form,
	.fields {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	form {
		gap: 28px;
	}
</style>
