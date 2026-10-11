<!--
	Home (Blueprint 25, Slice 28). Every leader gets the overview of what they
	lead (Paper "Navigation v5" NV01/NV03); their own wallet is under My wallet
	(/app/wallet). Members get the wallet Home (Paper H04, Blueprint 20 cache).
	Until the capabilities are known the saved Home kind stands in.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import type { NavModel } from '#lib/nav.js';
	import NetworkOverview from '#lib/ui/app/NetworkOverview.svelte';
	import WalletHome from '#lib/ui/app/WalletHome.svelte';

	const nav = getContext<() => NavModel>('nav');
	const network = $derived(nav().networkHome);
	/** A leader below the President Team also sees what their scope holds (was Team overview). */
	const held = $derived(nav().wallet);
</script>

<svelte:head><title>Home · Elivate Wallet</title></svelte:head>

{#if network}
	<NetworkOverview heldFigures={held} />
{:else}
	<WalletHome />
{/if}
