<!-- PIN locked: the only action is the reset email (plan §4.1). Paper "11 — Sign-in issue" pattern. -->
<script lang="ts">
	import Lock from '@lucide/svelte/icons/lock-keyhole';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
</script>

<svelte:head><title>PIN locked · Elivate Wallet</title></svelte:head>

<AuthHeading
	icon={Lock}
	tone="danger"
	eyebrow="PIN locked"
	title="Your PIN is locked"
	lead="Reset it with a link sent to your email."
/>
<form method="POST" action="/pin/forgot">
	<PrimaryButton label="Email me a reset link" />
</form>
<SignOutLink />
