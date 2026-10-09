<!--
	New password after a Recovery link, Paper "App — Screens v4" Z03 (owner
	approved 2026-10-08): verified email (read-only), new password, then the
	PIN as usual.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import Check from '@lucide/svelte/icons/check';
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

<svelte:head><title>Set a new password · Elivate Wallet</title></svelte:head>

<AuthHeading
	eyebrow="Recovery"
	title="Set a new password"
	lead="Then you’ll confirm with your PIN as usual."
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
		{#if data.email}
			<LockedField id="account-email" label="Email" value={data.email} locked={false}>
				{#snippet trailing()}
					<span class="verified"
						><Check size={14} strokeWidth={2} aria-hidden="true" />Verified</span
					>
				{/snippet}
			</LockedField>
		{/if}
		<Field
			id="password"
			name="password"
			type="password"
			label="New password"
			placeholder="Create a new password"
			autocomplete="new-password"
			minlength={MIN_PASSWORD}
			error={form?.error}
		/>
	</div>
	<PrimaryButton label="Save new password" {busy} />
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

	@media (min-width: 1024px) {
		form {
			gap: 32px;
		}
	}
</style>
