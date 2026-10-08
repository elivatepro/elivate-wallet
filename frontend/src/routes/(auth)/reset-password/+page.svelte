<!--
	New password after a Recovery link. Reuses Paper "Authentication v2" 09 Set
	password; a recovery-specific composition waits on owner approval.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import LockedField from '#lib/ui/auth/LockedField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { MIN_PASSWORD } from '../credentials';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);
</script>

<svelte:head><title>Choose a new password · Elivate Wallet</title></svelte:head>

<AuthHeading
	eyebrow="Recovery"
	title="Choose a new password"
	lead="Set a new password for the email below. Other devices will be signed out."
/>
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
		{#if data.email}<LockedField id="account-email" label="Email" value={data.email} />{/if}
		<Field
			id="password"
			name="password"
			type="password"
			label="New password"
			placeholder="Create a password"
			autocomplete="new-password"
			minlength={MIN_PASSWORD}
			hint={`At least ${MIN_PASSWORD} characters.`}
			error={form?.error}
		/>
	</div>
	<PrimaryButton label="Save password" {busy} />
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

	@media (min-width: 1024px) {
		form {
			gap: 32px;
		}
	}
</style>
