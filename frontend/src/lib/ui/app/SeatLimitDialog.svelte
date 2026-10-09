<!--
	Seat limit (Blueprint 16, D-10): Paper "App — Screens v1" E03/E04 for people
	who can't change the plan ("Ask your President to make room · Got it"), and
	for those who can pay, an Upgrade that opens Billing's PL05 dialog.
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { goto } from '$app/navigation';
	import OrgDialog from '#lib/ui/org/OrgDialog.svelte';

	let { open = $bindable(false), canUpgrade }: { open?: boolean; canUpgrade: boolean } = $props();
</script>

<OrgDialog
	bind:open
	pose="seat-limit"
	title="Can’t add members right now"
	subtitle={canUpgrade ? 'Move up a plan to keep adding people' : 'Ask your President to make room'}
	confirmLabel={canUpgrade ? 'Upgrade' : 'Got it'}
	cancelLabel="Not now"
	needsReason={false}
	needsPin={false}
	onConfirm={() => {
		open = false;
		if (canUpgrade) void goto('/app/billing?upgrade=1');
	}}
>
	{#snippet secondary()}
		{#if canUpgrade}<button type="button" class="org-cancel" onclick={() => (open = false)}
				>Not now</button
			>{:else}<span></span>{/if}
	{/snippet}
</OrgDialog>
