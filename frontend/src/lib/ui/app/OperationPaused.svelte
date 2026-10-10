<!--
	Operation paused by Elivate (Blueprint 18, owner answer Q4; Paper "App —
	Screens v2" X-series "withdrawals paused"): the traffic-cone Root in the
	X01/X03 whole-page layout. Money stays readable; open requests keep their
	place. The database refuses the operation either way.
-->
<script lang="ts">
	import StateScreen from './StateScreen.svelte';
	import { OPERATION_NAMES } from '#lib/operations.js';

	let { operation, headingLevel = 1 }: { operation: string; headingLevel?: 1 | 2 } = $props();
	const name = $derived(OPERATION_NAMES[operation] ?? 'This');
	const verb = $derived(name.endsWith('s') && !name.startsWith('Recording') ? 'are' : 'is');
</script>

<StateScreen
	pose="operation-paused"
	eyebrow="Paused"
	title={`${name} ${verb} paused for now`}
	lead="Your money is safe; open requests keep their place."
	{headingLevel}
>
	{#snippet actions()}
		<a class="state-primary" href="/app">Go to Home</a>
	{/snippet}
</StateScreen>
