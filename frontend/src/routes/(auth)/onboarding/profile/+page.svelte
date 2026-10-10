<!-- Wizard step 3 · profile. Paper "Onboarding — Invited member" 09 + 10 (rank wheel). -->
<script lang="ts">
	import { enhance } from '$app/forms';
	import { profilePhotoSrc } from '#lib/client/photo.js';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import PhoneField from '#lib/ui/onboarding/PhoneField.svelte';
	import PhotoField from '#lib/ui/onboarding/PhotoField.svelte';
	import RankPicker from '#lib/ui/onboarding/RankPicker.svelte';
	import WizardProgress from '#lib/ui/onboarding/WizardProgress.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);
	/** Slice 21: Continue waits while the chosen photo is shrunk. */
	let converting = $state(false);
	useRoot('onboard-profile', 'md');
	const errors = $derived<Record<string, string>>((form?.errors as Record<string, string>) ?? {});
</script>

<svelte:head><title>Your profile · Elivate Wallet</title></svelte:head>

<WizardProgress step={3} backHref="/onboarding/details" />
<AuthHeading
	eyebrow="Step 3 · Profile"
	title="Suit up your profile"
	lead="Add a photo, your phone number and your rank in the business."
/>
<form
	method="POST"
	enctype="multipart/form-data"
	novalidate
	use:enhance={({ cancel }) => {
		if (converting) return cancel();
		busy = true;
		return async ({ update }) => {
			await update({ reset: false });
			busy = false;
		};
	}}
>
	{#if data.photoRequired}
		<!-- Shown only once photo storage (R2) is bound; then it is required. -->
		<PhotoField
			hasPhoto={data.hasPhoto}
			photoSrc={profilePhotoSrc(data)}
			error={errors.photo}
			bind:converting
		/>
	{/if}
	<PhoneField value={data.phone ?? ''} locked={data.phoneLocked} error={errors.phone} />
	<RankPicker value={form?.rank ?? data.rank} error={errors.rank} />
	<PrimaryButton label="Continue" busy={busy || converting} />
</form>

<style>
	form {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}
</style>
