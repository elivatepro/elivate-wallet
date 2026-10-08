<!-- Paper "Authentication v2" · 05 Check your inbox. Neutral: no promise an account exists. -->
<script lang="ts">
	import Mail from '@lucide/svelte/icons/mail';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
</script>

<svelte:head><title>Check your inbox · Elivate Wallet</title></svelte:head>

<AuthHeading
	icon={Mail}
	eyebrow="Verify email"
	title="Check your inbox"
	lead="If an account can be created for that address, verification instructions will be sent."
/>
<PrimaryButton label="Back to sign in" href="/sign-in" />
