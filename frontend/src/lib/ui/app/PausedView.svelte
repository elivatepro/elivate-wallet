<!--
	Paused network, write page (Blueprint 16 Part A item 7, Paper "App —
	Screens v4" PL06): the PL06 sleep-mask Root and banner copy in the X01/X03
	whole-page layout. Owner decisions Q10/Q11: leaders and the Billing Owner
	(`canPay`) get "History stays available. Pay to turn it back on." with
	**Review billing**; everyone else keeps view-only access. The backend still
	refuses every paused write (`network_not_active`).
-->
<script lang="ts">
	import StateScreen from './StateScreen.svelte';

	let {
		network,
		canPay,
		headingLevel = 1
	}: {
		network: string;
		/** manage_subscription holders and the Billing Owner. */
		canPay: boolean;
		headingLevel?: 1 | 2;
	} = $props();
</script>

<StateScreen
	pose="dialog-sign-out"
	eyebrow="Paused"
	title={`${network} is paused`}
	lead={canPay
		? 'History stays available. Pay to turn it back on.'
		: 'Your money is safe to view. This is off until it’s renewed.'}
	{headingLevel}
>
	{#snippet actions()}
		{#if canPay}
			<a class="state-primary" href="/app/billing">Review billing</a>
			<a class="state-ghost" href="/app">Go to Home</a>
		{:else}
			<a class="state-primary" href="/app">Go to Home</a>
		{/if}
	{/snippet}
</StateScreen>
