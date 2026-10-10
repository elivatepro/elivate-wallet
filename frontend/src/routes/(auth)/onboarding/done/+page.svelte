<!--
	Wizard all set. Paper "Onboarding — Invited member" 13. Blueprint 22: the
	light setup (no wallet) lists the profile and the PIN, and continues to the
	app (or, for a founder, to naming the network).
-->
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
		...(data.light
			? [{ label: 'Profile', value: 'Done' }]
			: [{ label: 'Identity', value: data.identity ?? 'Verified' }]),
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
	const action = $derived(
		data.toSetup ? 'Set up your network' : data.light ? 'Continue' : 'Go to my wallet'
	);
</script>

<svelte:head><title>You’re all set · Elivate Wallet</title></svelte:head>

<WizardProgress step={data.total} total={data.total} complete />
<AuthHeading
	eyebrow="All set"
	title={data.firstName ? `You’re all set, ${data.firstName}` : 'You’re all set'}
	lead={data.light
		? 'Your account is ready. Root will be around whenever you need a hand.'
		: 'Your wallet is ready. Root will be around whenever you need a hand.'}
/>
<SummaryCard {rows} />
<PrimaryButton label={action} href="/onboarding/finish" />
