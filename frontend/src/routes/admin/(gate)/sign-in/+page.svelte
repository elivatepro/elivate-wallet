<!-- Paper "Admin — Screens v1" A01 / A02b · Admin sign-in (step 1 of 2). -->
<script lang="ts">
	import { enhance } from '$app/forms';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { form }: PageProps = $props();
	let busy = $state(false);
	useRoot('admin-sign-in', 'lg');
</script>

<svelte:head><title>Sign in · Elivate Admin</title></svelte:head>

<AuthHeading eyebrow="Step 1 of 2" title="Admin sign-in" />

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
		<Field
			id="email"
			name="email"
			type="email"
			label="Email address"
			placeholder="you@elivatewallet.com"
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
		/>
	</div>
	<PrimaryButton label="Continue" {busy} />
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
