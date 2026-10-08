<!-- PIN reset request. Paper "06/07 — Recovery" compositions. -->
<script lang="ts">
	import { enhance } from '$app/forms';
	import KeyRound from '@lucide/svelte/icons/key-round';
	import Mail from '@lucide/svelte/icons/mail';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
	import type { PageProps } from './$types';

	let { form }: PageProps = $props();
	let busy = $state(false);

	const minutesLeft = (iso: string) =>
		Math.max(1, Math.round((Date.parse(iso) - Date.now()) / 60_000));
</script>

<svelte:head><title>Reset your PIN · Elivate Wallet</title></svelte:head>

{#if form && 'sent' in form && form.sent}
	<AuthHeading
		icon={Mail}
		eyebrow="Reset PIN"
		title="Check your inbox"
		lead={`We sent a reset link to your email. It works for ${minutesLeft(form.expiresAt)} minutes.`}
	/>
	<SignOutLink />
{:else}
	<AuthHeading
		icon={KeyRound}
		eyebrow="Reset PIN"
		title="Forgot your PIN?"
		lead="We’ll email you a link to choose a new one."
	/>
	<form
		method="POST"
		use:enhance={() => {
			busy = true;
			return async ({ update }) => {
				await update();
				busy = false;
			};
		}}
	>
		{#if form && 'message' in form && form.message}<FormAlert message={form.message} />{/if}
		<PrimaryButton label="Send reset link" {busy} />
	</form>
	<SignOutLink />
{/if}

<style>
	form {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}
</style>
