<!-- account_blocked (suspended or deactivated account): status plus sign out. Paper G09. -->
<script lang="ts">
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';

	useRoot('blocked');
</script>

<svelte:head><title>Account unavailable · Elivate Wallet</title></svelte:head>

<AuthHeading
	eyebrow="Account"
	title="This account can’t be used right now"
	lead="Contact Elivate support if you think this is a mistake."
/>
<SignOutLink label="Sign out" />
