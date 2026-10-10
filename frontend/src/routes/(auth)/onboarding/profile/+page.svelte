<!--
	Wizard profile step. Paper "Onboarding — Invited member" 09 + 10 (rank
	wheel). Blueprint 22: the light setup (no wallet) asks for the first and
	last name instead of the phone, as step 2 of 2.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import { profilePhotoSrc } from '#lib/client/photo.js';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
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
	const echo = (key: 'firstName' | 'lastName') =>
		form && key in form ? String(form[key as keyof typeof form] ?? '') : (data[key] ?? '');
</script>

<svelte:head><title>Your profile · Elivate Wallet</title></svelte:head>

<WizardProgress
	step={data.step}
	total={data.total}
	backHref={data.light ? undefined : '/onboarding/details'}
/>
<AuthHeading
	eyebrow={`Step ${data.step} · Profile`}
	title="Suit up your profile"
	lead={data.light
		? 'Add your name, a photo and your rank in the business.'
		: 'Add a photo, your phone number and your rank in the business.'}
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
	{#if data.names}
		<Field
			id="firstName"
			name="firstName"
			label="First name"
			autocomplete="given-name"
			value={echo('firstName')}
			error={errors.firstName}
			maxlength={80}
		/>
		<Field
			id="lastName"
			name="lastName"
			label="Last name"
			autocomplete="family-name"
			value={echo('lastName')}
			error={errors.lastName}
			maxlength={80}
		/>
	{/if}
	<PhotoField
		hasPhoto={data.hasPhoto}
		photoSrc={profilePhotoSrc(data)}
		error={errors.photo}
		bind:converting
	/>
	{#if !data.light}
		<PhoneField value={data.phone ?? ''} locked={data.phoneLocked} error={errors.phone} />
	{/if}
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
