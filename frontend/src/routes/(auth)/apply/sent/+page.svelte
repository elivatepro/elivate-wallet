<!--
	Paper "Authentication v2" 14d/14m · Application received (Blueprint 19).
	The same page for every accepted form: it never says whether a new
	application was stored.
-->
<script lang="ts">
	import ClipboardCheck from '@lucide/svelte/icons/clipboard-check';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';

	useRoot('apply-sent', 'md');
</script>

<svelte:head><title>Application sent · Elivate Wallet</title></svelte:head>

<AuthHeading
	icon={ClipboardCheck}
	eyebrow="Application sent"
	title="We have your application"
	lead="Elivate reviews every application. We will email you either way, and an approved application comes with an invitation to set up your network."
/>
<PrimaryButton label="Back to sign in" href="/sign-in" />
