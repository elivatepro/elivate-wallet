<!-- Paper "Authentication v2" · 01/02/03 Sign in. -->
<script lang="ts">
	import { enhance } from '$app/forms';
	import { onMount } from 'svelte';
	import { purgeAllDeviceData } from '#lib/client/device-cache.js';
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

	// Nobody is signed in here, so no cached wallet data may remain on this
	// device (decision 36a: erased on sign-out).
	onMount(() => purgeAllDeviceData());
</script>

<svelte:head><title>Sign in · Elivate Wallet</title></svelte:head>

<AuthHeading eyebrow="Sign in" title="Welcome back" />

<form
	method="POST"
	novalidate
	use:enhance={() => {
		busy = true;
		return async ({ update }) => {
			await update({ reset: false });
			busy = false;
			// Each Turnstile token verifies once; get a fresh one for a retry.
			turnstile?.reset();
		};
	}}
>
	{#if form?.message}<FormAlert message={form.message} />{/if}
	<div class="fields">
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
		<Field
			id="password"
			name="password"
			type="password"
			label="Password"
			placeholder="Enter your password"
			autocomplete="current-password"
			error={form?.errors?.password}
		>
			{#snippet trailing()}<a class="forgot" href="/forgot-password">Forgot password?</a>{/snippet}
		</Field>
		<Turnstile
			bind:this={turnstile}
			bind:failed={checkFailed}
			siteKey={data.turnstileSiteKey}
			action="sign-in"
			retryLabel="sign in"
			theme={data.theme === 'system' ? 'auto' : data.theme}
		/>
	</div>
	<div class="actions">
		<PrimaryButton label="Sign in" {busy} disabled={checkFailed} />
		<AltLink prompt="New to Elivate?" label="Start your network" href="/apply" />
	</div>
</form>

<style>
	/* Paper "Authentication v2" 02/03: #FF9872 on dark, #B74725 on light. */
	.forgot {
		display: inline-flex;
		align-items: center;
		min-height: var(--hit-min);
		color: #ff9872;
		font-size: var(--text-14);
		line-height: var(--leading-20);
		text-decoration: none;
	}

	:global([data-theme='light']) .forgot {
		color: #b74725;
	}

	@media (prefers-color-scheme: light) {
		:global([data-theme='system']) .forgot {
			color: #b74725;
		}
	}

	form,
	.fields,
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
