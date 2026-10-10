<!-- Wizard Welcome. Paper "Onboarding — Invited member" 01. -->
<script lang="ts">
	import { ROLE_LABELS } from '#lib/labels.js';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import SummaryCard from '#lib/ui/onboarding/SummaryCard.svelte';
	import WizardProgress from '#lib/ui/onboarding/WizardProgress.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	useRoot('onboard-welcome');
	const rows = $derived([
		...(data.workspace.officeName ? [{ label: 'Office', value: data.workspace.officeName }] : []),
		{ label: 'Role', value: ROLE_LABELS[data.workspace.role] }
	]);
</script>

<svelte:head><title>Welcome · Elivate Wallet</title></svelte:head>

<WizardProgress step={0} total={data.total} />
<AuthHeading
	eyebrow="Invitation accepted"
	title={`Welcome to ${data.workspace.tenantName}`}
	lead={data.light
		? 'Root will help you set up your account in two quick steps.'
		: 'Root will help you set up your wallet in four quick steps.'}
/>
<SummaryCard {rows} />
<PrimaryButton label="Let’s begin" href="/onboarding/continue" />
