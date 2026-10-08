<!-- One truthful state for expired or used email links. Paper "App — Screens v3" G03. -->
<script lang="ts">
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';

	useRoot('link-expired');
</script>

<svelte:head><title>Link unavailable · Elivate Wallet</title></svelte:head>

<AuthHeading
	eyebrow="Link unavailable"
	title="This link has expired"
	lead="It may have been used already. Sign in to get a new one."
/>
<PrimaryButton label="Back to sign in" href="/sign-in" />
