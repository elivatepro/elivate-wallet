<!--
	Home (Blueprint 25). A workspace that holds the person's own wallet gets the
	wallet Home (Paper H04, Blueprint 20 cache); a leadership workspace that holds
	no money (the President Team, a director whose funds are not managed) gets
	the network overview (Paper "Navigation v5" NV01/NV03). Until the
	capabilities are known the wallet Home shows its saved copy, as before.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import type { NavModel } from '#lib/nav.js';
	import NetworkOverview from '#lib/ui/app/NetworkOverview.svelte';
	import WalletHome from '#lib/ui/app/WalletHome.svelte';

	const nav = getContext<() => NavModel>('nav');
	const network = $derived(nav().networkHome);
</script>

<svelte:head><title>Home · Elivate Wallet</title></svelte:head>

{#if network}
	<NetworkOverview />
{:else}
	<WalletHome />
{/if}
