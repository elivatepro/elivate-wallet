<!--
	Team overview (W-07 Leadership). Blueprint 25: the same network overview as
	a wallet-less leader's Home (Paper "Navigation v5" NV01/NV03), named after
	the workspace's scope and with what is reserved and available. It replaces
	the T01/T04 composition; one aggregate read for the scope, excluded scope
	said out loud, one currency at a time, never a cross-currency total.
-->
<script lang="ts">
	import NetworkOverview from '#lib/ui/app/NetworkOverview.svelte';
</script>

<svelte:head><title>Team overview · Elivate Wallet</title></svelte:head>

<NetworkOverview greeting={false} heldFigures />
