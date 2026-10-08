<!-- One truthful state for expired or used email links. Paper "10 — Invitation unavailable" pattern. -->
<script lang="ts">
	import LinkIcon from '@lucide/svelte/icons/link-2-off';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
</script>

<svelte:head><title>Link unavailable · Elivate Wallet</title></svelte:head>

<AuthHeading
	icon={LinkIcon}
	tone="danger"
	eyebrow="Link unavailable"
	title="This link has expired"
	lead="It may have been used already. Sign in to get a new one."
/>
<PrimaryButton label="Back to sign in" href="/sign-in" />
