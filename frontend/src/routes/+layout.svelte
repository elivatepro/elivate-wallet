<script lang="ts">
	import '@fontsource-variable/lexend/wght.css';
	import '@fontsource/ibm-plex-mono/latin-400.css';
	import '#lib/ui/base.css';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();
</script>

<svelte:head>
	<title>Elivate Wallet</title>
</svelte:head>

{@render children()}
