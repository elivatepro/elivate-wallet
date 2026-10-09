<!--
	What a leader submitted for a conversion, adjustment or returned funds
	(Blueprint 12), for the evidence reviewer (W-11): the member, the exact
	facts, the policy split of an adjustment, and the evidence files (opened
	through the app server; the browser never sees a storage URL).
-->
<script lang="ts">
	import FileText from '@lucide/svelte/icons/file-text';
	import { EntryAppRoutes, type Entry, type Returnable } from '#lib/contract/entries.js';
	import { initials } from '#lib/activity.js';
	import { formatMoney } from '#lib/money.js';
	import { entryTitle, formatRate } from '#lib/entries.js';

	let { entry, returnable = null }: { entry: Entry; returnable?: Returnable | null } = $props();

	const when = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(
			new Date(iso)
		);
	const who = $derived(entry.member?.name ?? entry.member?.uid ?? 'Member');
	const by = $derived(entry.submittedBy?.name ?? entry.submittedBy?.uid ?? '—');
	const c = $derived(entry.conversion);
</script>

<div class="mm-section">
	<div class="mm-spread who">
		<span class="mm-avatar lg">{initials(entry.member?.name, entry.member?.uid ?? '')}</span>
		<div class="mm-names grow">
			<span class="mm-box-title">{who}</span>
			<span class="mm-box-sub">{entry.office.name} · submitted by {by}</span>
		</div>
	</div>
</div>

<div class="mm-section">
	<div class="mm-spread">
		<span class="mm-muted">Type</span><span class="mm-value">{entryTitle(entry)}</span>
	</div>
	{#if c}
		<div class="mm-spread">
			<span class="mm-muted">Converted from</span>
			<span class="mm-value">{formatMoney(entry.amount, entry.currency)}</span>
		</div>
		<div class="mm-spread">
			<span class="mm-muted">Actually received</span>
			<span class="mm-value">{formatMoney(c.destinationAmount, c.destinationCurrency)}</span>
		</div>
		<div class="mm-spread">
			<span class="mm-muted">Effective rate</span>
			<span class="mm-value">{formatRate(c.effectiveRate, c.rateQuote, c.rateBase)}</span>
		</div>
		{#if c.quotedRate}
			<div class="mm-spread">
				<span class="mm-muted">Quoted rate</span>
				<span class="mm-value">{formatRate(c.quotedRate, c.rateQuote, c.rateBase)}</span>
			</div>
		{/if}
	{:else}
		<div class="mm-spread">
			<span class="mm-muted">Amount</span>
			<span class="mm-value"
				>{formatMoney(
					entry.direction === 'debit' ? `-${entry.amount}` : entry.amount,
					entry.currency,
					true
				)}</span
			>
		</div>
	{/if}
	{#if entry.pocket}
		<div class="mm-spread">
			<span class="mm-muted">Pocket</span><span class="mm-value">{entry.pocket.name}</span>
		</div>
	{/if}
	{#if entry.provider}
		<div class="mm-spread">
			<span class="mm-muted">{entry.kind === 'returned_funds' ? 'Returned by' : 'Provider'}</span>
			<span class="mm-value">{entry.provider}</span>
		</div>
	{/if}
	{#if entry.observedAt}
		<div class="mm-spread">
			<span class="mm-muted"
				>{entry.kind === 'returned_funds' ? 'Seen in account' : 'Converted at'}</span
			>
			<span class="mm-value">{when(entry.observedAt)}</span>
		</div>
	{/if}
	{#if entry.externalReference}
		<div class="mm-spread">
			<span class="mm-muted">Reference</span><span class="mm-value mono"
				>{entry.externalReference}</span
			>
		</div>
	{/if}
	{#if entry.withdrawal}
		<div class="mm-spread">
			<span class="mm-muted">Withdrawal</span><span class="mm-value mono"
				>{entry.withdrawal.reference}</span
			>
		</div>
	{/if}
	{#if returnable}
		<div class="mm-spread">
			<span class="mm-muted">Paid out · already returned</span>
			<span class="mm-value"
				>{formatMoney(returnable.paidOut, returnable.currency)} · {formatMoney(
					returnable.returned,
					returnable.currency
				)}</span
			>
		</div>
	{/if}
	{#if entry.reason}<p class="mm-note">“{entry.reason}”</p>{/if}
	{#if entry.notes}<p class="mm-note">{entry.notes}</p>{/if}
</div>

{#if entry.lines?.length}
	<div class="mm-section">
		<span class="mm-label">Split by allocation policy</span>
		{#each entry.lines.filter((l) => !/^0(\.0+)?$/.test(l.amount)) as line (line.pocketId)}
			<div class="mm-spread">
				<span class="mm-muted">{line.pocket} · {line.basisPoints / 100}%</span>
				<span class="mm-value">{formatMoney(line.amount, entry.currency)}</span>
			</div>
		{/each}
	</div>
{/if}

<div class="mm-section">
	<span class="mm-label">Evidence</span>
	{#each entry.evidence as file (file.evidenceId)}
		<div class="mm-box">
			<FileText size={18} strokeWidth={1.6} aria-hidden="true" />
			<div class="mm-names grow">
				<a
					class="mm-box-title file-link"
					href={EntryAppRoutes.evidence(entry.entryId, file.evidenceId)}
					target="_blank"
					rel="noopener">{file.name}</a
				>
				<span class="mm-box-sub">Sent {when(entry.createdAt)}</span>
			</div>
		</div>
	{/each}
</div>

<style>
	.grow {
		flex: 1;
	}

	.who {
		justify-content: flex-start;
	}

	.mono {
		font-family: var(--font-mono);
	}

	.file-link {
		color: var(--color-text);
		text-decoration: none;
	}

	.file-link:hover {
		text-decoration: underline;
	}
</style>
