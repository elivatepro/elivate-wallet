<!--
	Transaction detail, Paper "App — Screens v1" M03 right panel (desktop split
	panel, 380 px) and M05 (mobile full page). Type / From / To / Date /
	Recorded by / Reference, then the exact split it was posted with. No
	redundant "Transaction" heading (W-07). Amounts are the ledger's strings.
	"Ask support" is left out until the support slice lands.
-->
<script lang="ts">
	import { page } from '$app/state';
	import Check from '@lucide/svelte/icons/check';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import Copy from '@lucide/svelte/icons/copy';
	import X from '@lucide/svelte/icons/x';
	import type { Currency, TransactionDetail } from '#lib/contract/ledger.js';
	import { statusLabel, statusTone, typeLabel } from '#lib/activity.js';
	import { formatMoney, hiddenMoney, isZero, sumMoney } from '#lib/money.js';

	let {
		detail,
		variant = 'panel',
		owner = null,
		hideAmounts = false,
		onClose
	}: {
		detail: TransactionDetail;
		variant?: 'panel' | 'page';
		/** Managed view: whose wallet this is ("Kemi Okafor"); null for your own. */
		owner?: string | null;
		hideAmounts?: boolean;
		onClose?: () => void;
	} = $props();

	const DOTS = [
		'var(--color-accent)',
		'var(--color-success)',
		'var(--color-info)',
		'var(--color-warning)',
		'#c9a3ff',
		'var(--color-muted)'
	];

	const journal = $derived(detail.journals[0] ?? null);
	const currency = $derived<Currency | null>(detail.income?.currency ?? journal?.currency ?? null);
	const amount = $derived(
		detail.income?.amount ?? sumMoney((journal?.lines ?? []).map((l) => l.amount))
	);
	const money = (value: string, c: Currency, signed = false) =>
		hideAmounts ? hiddenMoney(c) : formatMoney(value, c, signed);
	const recorder = $derived(detail.recordedBy?.name ?? detail.recordedBy?.uid ?? null);
	const when = $derived(
		new Intl.DateTimeFormat('en-GB', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		})
			.format(new Date(detail.postedAt))
			.replace(' at ', ', ')
	);
	const day = $derived(
		new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }).format(
			new Date(detail.postedAt)
		)
	);
	const reversed = $derived(detail.reversedBy ?? null);
	const short = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short' }).format(new Date(iso));
	const lead = $derived.by(() => {
		if (detail.reverses) return `Reversal of ${detail.reverses.reference}.`;
		if (!detail.income) return null;
		if (reversed)
			return `Income from ${detail.income.source}. Reversed on ${short(reversed.postedAt)}.`;
		const by = recorder ? `, recorded by ${recorder}` : '';
		const whose = owner ? 'their' : 'your';
		return `Income from ${detail.income.source}${by} and split across ${whose} pockets.`;
	});
	/** Same page, another transaction (keeps ?wallet= for managed views). */
	const hrefFor = (id: string) => {
		const url = new URL(page.url.href);
		url.searchParams.set('tx', id);
		return `${url.pathname}${url.search}`;
	};
	const stamp = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		})
			.format(new Date(iso))
			.replace(' at ', ', ');
	const history = $derived(
		[
			reversed
				? {
						tone: 'danger',
						title: `Reversed · ${reversed.reference}`,
						sub: `${stamp(reversed.postedAt)} · taken back from ${owner ? 'their' : 'your'} pockets`
					}
				: null,
			{
				tone: 'success',
				title: `Posted to ${owner ? 'their' : 'your'} pockets`,
				sub: stamp(detail.postedAt)
			},
			recorder
				? { tone: 'muted', title: `Recorded by ${recorder}`, sub: stamp(detail.postedAt) }
				: null
		].filter((h) => h !== null)
	);
	const split = $derived(
		(detail.income?.allocations ?? [])
			.map((a, i) => ({ ...a, dot: DOTS[i % DOTS.length] }))
			.filter((a) => !isZero(a.amount))
	);
	const tone = $derived(statusTone(detail.status));

	let copied = $state(false);
	async function copyReference() {
		try {
			await navigator.clipboard.writeText(detail.reference);
			copied = true;
			setTimeout(() => (copied = false), 1500);
		} catch {
			copied = false;
		}
	}
</script>

{#snippet rows()}
	<dl class="rows">
		<div class="row">
			<dt>Type</dt>
			<dd>{typeLabel(detail.type)}</dd>
		</div>
		{#if detail.income}
			<div class="row">
				<dt>From</dt>
				<dd>{detail.income.source}</dd>
			</div>
		{/if}
		{#if currency}
			<div class="row">
				<dt>To</dt>
				<dd>{owner ? `${owner}’s wallet` : 'Your wallet'} · {currency}</dd>
			</div>
		{/if}
		<div class="row">
			<dt>Date</dt>
			<dd>{when}</dd>
		</div>
		{#if recorder}<div class="row">
				<dt>Recorded by</dt>
				<dd>{recorder}</dd>
			</div>{/if}
		{#if detail.reverses}
			<div class="row center">
				<dt>Reverses</dt>
				<dd class="ref">
					<a class="mono link" href={hrefFor(detail.reverses.transactionId)}
						>{detail.reverses.reference}</a
					>
				</dd>
			</div>
		{/if}
		<div class="row center">
			<dt>Reference</dt>
			<dd class="ref">
				<span class="mono">{detail.reference}</span>
				<button
					type="button"
					class="copy"
					onclick={copyReference}
					aria-label={copied ? 'Reference copied' : 'Copy reference'}
				>
					{#if copied}<Check size={14} strokeWidth={2} aria-hidden="true" />{:else}<Copy
							size={14}
							strokeWidth={2}
							aria-hidden="true"
						/>{/if}
				</button>
			</dd>
		</div>
		{#if reversed}
			<div class="row center">
				<dt>Reversed by</dt>
				<dd class="ref">
					<a class="mono link" href={hrefFor(reversed.transactionId)}>{reversed.reference}</a>
				</dd>
			</div>
		{/if}
	</dl>
{/snippet}

{#snippet historyBlock()}
	<section class="split" aria-label="History">
		<p class="kicker">History</p>
		<ol class="history">
			{#each history as h (h.title)}
				<li>
					<span class="dot {h.tone}" aria-hidden="true"></span>
					<span class="h-text"
						><span class="h-title">{h.title}</span><span class="h-sub">{h.sub}</span></span
					>
				</li>
			{/each}
		</ol>
	</section>
{/snippet}

{#snippet splitBlock()}
	{#if split.length && currency}
		<section class="split" aria-label="Split into pockets">
			<p class="kicker">Split into pockets</p>
			<div class="bar" aria-hidden="true">
				{#each split as line (line.pocketId)}
					<span style:background={line.dot} style:flex-grow={line.basisPoints}></span>
				{/each}
			</div>
			<ul>
				{#each split as line (line.pocketId)}
					<li>
						<span class="pocket"
							><span class="dot" style:background={line.dot} aria-hidden="true"></span>{line.pocket} ·
							{line.basisPoints / 100}%</span
						>
						<span class="value">{money(line.amount, currency)}</span>
					</li>
				{/each}
			</ul>
		</section>
	{:else if !detail.income && journal?.lines?.length}
		<section class="split" aria-label="Pockets">
			<p class="kicker">Pockets</p>
			<ul>
				{#each journal.lines as line (line.pocketId)}
					<li>
						<span class="pocket">{line.pocket}</span>
						<span class="value">{money(line.amount, journal.currency, true)}</span>
					</li>
				{/each}
			</ul>
		</section>
	{/if}
{/snippet}

{#if variant === 'panel'}
	<aside class="panel" aria-label="Transaction {detail.reference}">
		<div class="top">
			<div class="top-row">
				<span class="pill {tone}">{statusLabel(detail.status)}</span>
				{#if onClose}
					<button type="button" class="icon" onclick={onClose} aria-label="Close details">
						<X size={18} strokeWidth={1.8} aria-hidden="true" />
					</button>
				{/if}
			</div>
			{#if currency}<p class="amount" class:struck={!!reversed}>
					{money(amount, currency, true)}
				</p>{/if}
			{#if lead}<p class="lead">{lead}</p>{/if}
		</div>
		<div class="block">{@render rows()}</div>
		{#if split.length || journal?.lines?.length}<div class="block">{@render splitBlock()}</div>{/if}
		{#if reversed}<div class="block">{@render historyBlock()}</div>{/if}
	</aside>
{:else}
	<article class="page" aria-label="Transaction {detail.reference}">
		<header class="nav">
			<button type="button" class="icon" onclick={onClose} aria-label="Back to activity">
				<ChevronLeft size={22} strokeWidth={2} aria-hidden="true" />
			</button>
			<span class="nav-title">{day}</span>
			<span class="icon-spacer" aria-hidden="true"></span>
		</header>
		<div class="hero">
			<span class="hero-icon" class:credit={!amount.startsWith('-')} aria-hidden="true">
				<svg width="24" height="24" viewBox="0 0 24 24"
					><path
						d={amount.startsWith('-') ? 'M12 19V5m0 0-6 6m6-6 6 6' : 'M12 5v14m0 0-6-6m6 6 6-6'}
						fill="none"
						stroke="currentColor"
						stroke-width="2"
						stroke-linecap="round"
						stroke-linejoin="round"
					/></svg
				>
			</span>
			<p class="hero-sub">
				{typeLabel(detail.type)}{detail.income ? ` · ${detail.income.source}` : ''}
			</p>
			{#if currency}<h1 class="hero-amount" class:struck={!!reversed} tabindex="-1">
					{money(amount, currency, true)}
				</h1>{/if}
			<span class="pill {tone} big">{statusLabel(detail.status)}</span>
		</div>
		<div class="cards">
			<div class="card">{@render rows()}</div>
			{#if split.length || journal?.lines?.length}<div class="card">
					{@render splitBlock()}
				</div>{/if}
		</div>
	</article>
{/if}

<style>
	.panel {
		display: flex;
		flex-direction: column;
		flex-shrink: 0;
		width: 380px;
		overflow: clip;
		border: 1px solid var(--line-soft, #ffffff14);
		border-radius: var(--radius-16);
		background: var(--color-surface);
	}

	.top {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 14px;
		padding: 24px;
		border-bottom: 1px solid #ffffff0f;
	}

	.top-row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		align-self: stretch;
	}

	.amount {
		color: var(--color-text);
		font-size: 34px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 40px;
	}

	.lead {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.block {
		padding: 20px 24px;
		border-bottom: 1px solid #ffffff0f;
	}

	.block:last-child {
		border-bottom: 0;
	}

	.pill {
		padding: 4px 10px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--color-text);
		font-size: var(--text-12);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-16);
	}

	.pill.success {
		background: color-mix(in oklab, var(--color-success) 16%, var(--color-surface));
		color: var(--color-success);
	}

	.pill.danger {
		background: color-mix(in oklab, var(--color-danger) 16%, var(--color-surface));
		color: var(--color-danger);
	}

	.struck {
		color: var(--color-muted);
		text-decoration: line-through;
		text-decoration-thickness: 2px;
	}

	.link {
		color: var(--color-accent);
		text-decoration: none;
	}

	.history {
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	.history li {
		display: flex;
		align-items: flex-start;
		gap: 12px;
	}

	.history .dot {
		margin-top: 5px;
		background: var(--color-muted);
	}

	.history .dot.danger {
		background: var(--color-danger);
	}

	.history .dot.success {
		background: var(--color-success);
	}

	.h-text {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.h-title {
		color: var(--color-text);
		font-size: 13px;
		line-height: 16px;
	}

	.h-sub {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: 16px;
	}

	.pill.big {
		padding: 4px 12px;
		font-size: 13px;
	}

	.icon {
		display: flex;
		align-items: center;
		justify-content: center;
		width: var(--hit-min, 44px);
		height: var(--hit-min, 44px);
		margin: -12px -12px -12px 0;
		border: 0;
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}

	.rows {
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	.row {
		display: flex;
		justify-content: space-between;
		gap: 16px;
		font-size: 13px;
		line-height: var(--leading-16);
	}

	.row.center {
		align-items: center;
	}

	dt {
		flex-shrink: 0;
		width: 100px;
		color: var(--color-muted);
	}

	dd {
		color: var(--color-text);
		text-align: right;
	}

	.ref {
		display: flex;
		align-items: center;
		gap: 6px;
	}

	.mono {
		font-family: var(--font-mono);
	}

	.copy {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 28px;
		height: 28px;
		margin: -6px -6px -6px 0;
		border: 0;
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}

	.split {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.kicker {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		letter-spacing: 0.08em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.bar {
		display: flex;
		gap: 3px;
		height: 8px;
	}

	.bar span {
		flex-basis: 0;
		border-radius: var(--radius-pill);
	}

	.split ul {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.split li {
		display: flex;
		justify-content: space-between;
		font-size: 13px;
		line-height: var(--leading-16);
	}

	.pocket {
		display: flex;
		align-items: center;
		gap: 8px;
		color: var(--shell-strong, var(--color-text));
	}

	.dot {
		flex-shrink: 0;
		width: 8px;
		height: 8px;
		border-radius: var(--radius-pill);
	}

	.value {
		color: var(--color-text);
	}

	/* ── Mobile page (M05) ── */

	.page {
		display: flex;
		flex-direction: column;
	}

	.nav {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 4px 0 8px;
	}

	.nav .icon {
		margin: 0;
		color: var(--color-text);
	}

	.icon-spacer {
		width: 44px;
	}

	.nav-title {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.hero {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 10px;
		padding: 20px 4px 28px;
		text-align: center;
	}

	.hero-icon {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 56px;
		height: 56px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--color-text);
	}

	.hero-icon.credit {
		background: color-mix(in oklab, var(--color-success) 16%, var(--color-canvas));
		color: var(--color-success);
	}

	.hero-sub {
		color: var(--color-muted);
		font-size: 15px;
		line-height: 18px;
	}

	.hero-amount {
		color: var(--color-text);
		font-size: 40px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.03em;
		line-height: 46px;
		outline: none;
	}

	.cards {
		display: flex;
		flex-direction: column;
		gap: 12px;
		padding-bottom: 32px;
	}

	.card {
		padding: 18px;
		border: 1px solid #ffffff14;
		border-radius: var(--radius-16);
		background: var(--color-surface);
	}

	:global([data-theme='light']) .panel,
	:global([data-theme='light']) .card {
		border-color: var(--color-border);
	}
</style>
