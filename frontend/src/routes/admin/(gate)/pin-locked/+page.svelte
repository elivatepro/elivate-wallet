<!-- Approved draft A01ed / A01em · PIN locked. -->
<script lang="ts">
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	useRoot('pin-locked', 'lg');
</script>

<svelte:head><title>PIN locked · Elivate Admin</title></svelte:head>

<AuthHeading
	eyebrow="PIN locked"
	title="Your PIN is locked"
	lead={form?.sent
		? `We sent a reset link${data.email ? ` to ${data.email}` : ''}.`
		: 'Five wrong tries. Reset it with a link we email you.'}
/>
{#if form?.error}<FormAlert message={form.error} />{/if}
<form method="POST">
	<PrimaryButton label={form?.sent ? 'Send the link again' : 'Email me a reset link'} />
</form>
<form class="alt" method="POST" action="/admin/sign-out">
	<button type="submit">Use a different account</button>
</form>

<style>
	form {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}
	.alt {
		align-items: center;
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
