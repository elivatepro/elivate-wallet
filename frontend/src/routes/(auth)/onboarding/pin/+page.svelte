<!-- Wizard step 1 · PIN. Paper "Onboarding — Invited member" 02/03. -->
<script lang="ts">
	import { enhance } from '$app/forms';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import WizardProgress from '#lib/ui/onboarding/WizardProgress.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);
	useRoot('onboard-pin');
</script>

<svelte:head><title>Create your PIN · Elivate Wallet</title></svelte:head>

<WizardProgress step={1} total={data.total} backHref="/onboarding" />
<AuthHeading
	eyebrow="Step 1 · Security"
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
	<PinField
		id="pin"
		name="pin"
		label="PIN"
		autocomplete="new-password"
		error={form?.errors?.pin}
		autofocus
	/>
	<PinField
		id="pinConfirm"
		name="pinConfirm"
		label="Repeat PIN"
		autocomplete="new-password"
		error={form?.errors?.pinConfirm}
	/>
	<PrimaryButton label="Save PIN" {busy} />
</form>

<style>
	form {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}
</style>
