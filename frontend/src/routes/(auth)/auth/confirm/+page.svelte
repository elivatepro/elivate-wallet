<!-- Email-link landing: one Continue button (POST). Paper "App — Screens v3" G01. -->
<script lang="ts">
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	let busy = $state(false);
	useRoot('confirm-email');
	// A Magic Link is a PIN reset unless an invitation is open in this browser.
	const isJoin = $derived(data.type === 'magiclink' && data.joining);
	const isReset = $derived(data.type === 'magiclink' && !data.joining);
	const title = $derived(
		isReset ? 'Reset your PIN' : isJoin ? 'Continue joining' : 'Confirm your email'
	);
</script>

<svelte:head>
	<title>{title} · Elivate Wallet</title>
</svelte:head>

<AuthHeading
	eyebrow={isReset ? 'Reset PIN' : isJoin ? 'Invitation' : 'Verify email'}
	{title}
	lead="Press Continue to finish on this device."
/>
<form method="POST" onsubmit={() => (busy = true)}>
	<input type="hidden" name="token_hash" value={data.tokenHash} />
	<input type="hidden" name="type" value={data.type} />
	<PrimaryButton label="Continue" {busy} />
</form>
