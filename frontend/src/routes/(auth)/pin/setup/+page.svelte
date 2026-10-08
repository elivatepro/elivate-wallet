<!--
	First PIN (W-01/W-22). Not drawn on its own in Paper; built from the
	"Enter your PIN" composition with a confirmation field.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
	import type { PageProps } from './$types';

	let { form }: PageProps = $props();
	let busy = $state(false);
</script>

<svelte:head><title>Create your PIN · Elivate Wallet</title></svelte:head>

<AuthHeading
	eyebrow="Security"
	title="Create your PIN"
	lead="4 digits you’ll enter each time you sign in."
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
	<div class="fields">
		<PinField id="pin" name="pin" label="PIN" autocomplete="new-password" error={form?.errors?.pin} autofocus />
		<PinField
			id="pinConfirm"
			name="pinConfirm"
			label="Repeat PIN"
			autocomplete="new-password"
			error={form?.errors?.pinConfirm}
		/>
	</div>
	<PrimaryButton label="Save PIN" {busy} />
</form>
<SignOutLink />

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
