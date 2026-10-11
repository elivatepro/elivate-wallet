<!--
	Team overview moved to Home (Slice 28: every leader's Home is the overview
	of what they lead). Old links and bookmarks land on Home.
-->
<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';

	onMount(() => void goto('/app', { replaceState: true }));
</script>

<svelte:head><title>Home · Elivate Wallet</title></svelte:head>
