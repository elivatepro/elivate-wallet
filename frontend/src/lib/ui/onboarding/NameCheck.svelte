<!--
	Resolved bank-account name and how it compares with the verified NIN name
	(Paper 11 matched, 12 mismatch, Y01 identity check pending). Status is text
	plus icon, never colour alone.
-->
<script lang="ts">
	import Check from '@lucide/svelte/icons/check';
	import Clock from '@lucide/svelte/icons/clock';
	import X from '@lucide/svelte/icons/x';
	import type { NameMatch } from '#lib/contract/payout.js';

	let {
		accountName,
		match,
		legalName
	}: { accountName: string; match: NameMatch; legalName: string | null } = $props();

	const note = $derived(
		match === 'matched'
			? 'Matches your verified name'
			: match === 'mismatched'
				? `Doesn’t match ${legalName ?? 'your verified name'}`
				: 'Identity check pending · you can still use it'
	);
</script>

<div class="check" data-match={match} role="status">
	<span class="icon" aria-hidden="true">
		{#if match === 'matched'}<Check
				size={16}
				strokeWidth={2.4}
			/>{:else if match === 'mismatched'}<X size={16} strokeWidth={2.4} />{:else}<Clock
				size={16}
				strokeWidth={2.2}
			/>{/if}
	</span>
	<div class="text">
		<p class="name">{accountName}</p>
		<p class="note">{note}</p>
	</div>
</div>

<style>
	.check {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 14px 16px;
		border-radius: var(--radius-12);
		border: 1px solid color-mix(in oklab, var(--tone) 40%, transparent);
		background: color-mix(in oklab, var(--tone) 10%, transparent);
		--tone: var(--color-success);
	}

	.check[data-match='mismatched'] {
		--tone: var(--color-danger);
	}

	.check[data-match='identity_pending'] {
		--tone: var(--color-warning);
	}

	.icon {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 28px;
		height: 28px;
		border-radius: var(--radius-pill);
		background: var(--tone);
		color: var(--auth-canvas);
	}

	.name {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: 0.02em;
		line-height: var(--leading-20);
		text-transform: uppercase;
		overflow-wrap: anywhere;
	}

	.note {
		color: var(--tone);
		font-size: 13px;
		line-height: 18px;
	}
</style>
