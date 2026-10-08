<!-- PIN locked: the only action is the reset email (plan §4.1). Paper "App — Screens v3" G05. -->
<script lang="ts">
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';

	useRoot('pin-locked');
</script>

<svelte:head><title>PIN locked · Elivate Wallet</title></svelte:head>

<AuthHeading
	eyebrow="PIN locked"
	title="Your PIN is locked"
	lead="Reset it with a link sent to your email."
/>
<form method="POST" action="/pin/forgot">
	<PrimaryButton label="Email me a reset link" />
</form>
<SignOutLink tight />
