<!--
	Paper "Authentication v2" · 06 Password recovery and 07 Recovery response.
	Neutral either way: no promise that an account exists or that email went out.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import Mail from '@lucide/svelte/icons/mail';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import Turnstile from '#lib/ui/auth/Turnstile.svelte';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);
	let turnstile: Turnstile | undefined = $state();
	let checkFailed = $state(false);
</script>

<svelte:head
	><title>{form?.sent ? 'Check for next steps' : 'Reset your password'} · Elivate Wallet</title
	></svelte:head
>

{#if form?.sent}
	<AuthHeading
		icon={Mail}
		eyebrow="Recovery"
		title="Check for next steps"
		lead="If the account can be recovered, reset instructions will be sent."
	/>
	<PrimaryButton label="Back to sign in" href="/sign-in" />
{:else}
	<AuthHeading
		eyebrow="Recovery"
		title="Reset your password"
		lead="Enter your email and we’ll send next steps if the account can be recovered."
	/>
	<form
		method="POST"
		novalidate
		use:enhance={() => {
			busy = true;
			return async ({ update }) => {
				await update({ reset: false });
				busy = false;
				turnstile?.reset();
			};
		}}
	>
		{#if form?.message}<FormAlert message={form.message} />{/if}
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
		<Turnstile
			bind:this={turnstile}
			bind:failed={checkFailed}
			siteKey={data.turnstileSiteKey}
			action="forgot-password"
			retryLabel="send reset instructions"
			theme={data.theme === 'system' ? 'auto' : data.theme}
		/>
		<div class="actions">
			<PrimaryButton label="Send reset instructions" {busy} disabled={checkFailed} />
			<AltLink label="Back to sign in" href="/sign-in" />
		</div>
	</form>
{/if}

<style>
	form,
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
