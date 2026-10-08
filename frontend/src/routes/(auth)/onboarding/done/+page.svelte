<!-- Wizard all set. Paper "Onboarding — Invited member" 13. -->
<script lang="ts">
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import SummaryCard from '#lib/ui/onboarding/SummaryCard.svelte';
	import WizardProgress from '#lib/ui/onboarding/WizardProgress.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	useRoot('onboard-done');
	const rows = $derived([
		{ label: 'Identity', value: data.identity },
		...(data.account
			? [
					{
						label: 'Payout account',
						value: `${data.account.bankName ?? 'Bank'} •• ${data.account.accountLast4}`
					}
				]
			: []),
		{ label: 'Transaction PIN', value: 'Set' }
	]);
</script>

<svelte:head><title>You’re all set · Elivate Wallet</title></svelte:head>

<WizardProgress step={4} complete />
<AuthHeading
	eyebrow="All set"
	title={data.firstName ? `You’re all set, ${data.firstName}` : 'You’re all set'}
	lead="Your wallet is ready. Root will be around whenever you need a hand."
/>
<SummaryCard {rows} />
<PrimaryButton label="Go to my wallet" href="/onboarding/finish" />
