<!-- Paper "Admin — Screens v1" A01b / A02 · Enter your PIN (step 2 of 2). -->
<script lang="ts">
	import { enhance } from '$app/forms';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);
	useRoot('admin-sign-in', 'lg');
</script>

<svelte:head><title>Enter your PIN · Elivate Admin</title></svelte:head>

<AuthHeading
	eyebrow="Step 2 of 2"
	title="Enter your PIN"
	lead={data.email ? `Your 4-digit PIN for ${data.email}` : 'Your 4-digit PIN'}
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
	{#key form}
		<PinField
			id="pin"
			name="pin"
			label="PIN"
			autocomplete="current-password"
			error={form?.error}
			autofocus
		/>
	{/key}
	<PrimaryButton label="Verify" {busy} />
</form>
<form class="alt" method="POST" action="/admin/sign-out">
	<button type="submit">Use a different account</button>
</form>

<style>
	form {
		display: flex;
		flex-direction: column;
		gap: 28px;
	}
	.alt {
		align-items: center;
		margin-top: -8px;
	}
	.alt button {
		min-height: var(--hit-min);
		border: 0;
		background: transparent;
		font: inherit;
		font-size: 14px;
		color: var(--auth-body);
		cursor: pointer;
	}
</style>
