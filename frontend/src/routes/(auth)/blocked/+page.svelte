<!-- account_blocked (suspended or deactivated account): status plus sign out. -->
<script lang="ts">
	import Ban from '@lucide/svelte/icons/ban';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
</script>

<svelte:head><title>Account unavailable · Elivate Wallet</title></svelte:head>

<AuthHeading
	icon={Ban}
	tone="danger"
	eyebrow="Account"
	title="This account can’t be used right now"
	lead="Contact Elivate support if you think this is a mistake."
/>
<SignOutLink label="Sign out" />
