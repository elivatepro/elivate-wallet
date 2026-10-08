<!--
	Activity, Paper "App — Screens v1" M03 (desktop, with the transaction split
	panel) and M04/M05 (mobile list, full-page detail). W-07: chronological,
	signed per-currency amounts, durable status, search, Money in / Money out
	and currency / status / pocket / date filters; all currencies and dates are
	shown until filtered. Month totals come from the backend's aggregate read.
	The selected transaction lives in the URL (?tx=) so back/forward work.
	Used for your own activity and, with `wallet`, a managed wallet's.
-->
<script lang="ts">
	import { getContext, untrack } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import { Cause, Effect, Exit, Option } from 'effect';
	import { DropdownMenu } from 'bits-ui';
	import ArrowDown from '@lucide/svelte/icons/arrow-down';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import Search from '@lucide/svelte/icons/search';
	import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
	import { ActivityView } from '#lib/contract/app.js';
	import type { ApiFailure } from '#lib/contract/errors.js';
	import {
		TransactionDetail as DetailSchema,
		type ActivityItem,
		type ActivityMonth,
		type Currency,
		type Pocket,
		type TransactionDetail
	} from '#lib/contract/ledger.js';
	import { getJson } from '#lib/client/api.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import {
		browserTimeZone,
		dateRange,
		DATE_RANGE_LABELS,
		groupByMonth,
		isCredit,
		monthLabel,
		monthTotals,
		STATUS_LABELS,
		statusLabel,
		statusTone,
		typeLabel,
		type DateRange
	} from '#lib/activity.js';
	import { formatMoney, hiddenMoney } from '#lib/money.js';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import TransactionDetailView from '#lib/ui/app/TransactionDetail.svelte';

	let {
		wallet = null,
		owner = null,
		heading = 'Activity'
	}: {
		/** Managed wallet id; null for your own activity. */
		wallet?: string | null;
		/** Managed view: the owner's name for the detail copy. */
		owner?: string | null;
		heading?: string;
	} = $props();

	const shell = getContext<Shell>('shell');
	const tz = browserTimeZone();

	let query = $state('');
	let appliedQuery = $state('');
	let direction = $state<'all' | 'in' | 'out'>('all');
	let currency = $state<Currency | 'all'>('all');
	let status = $state<string>('any');
	let pocketId = $state<string>('all');
	let range = $state<DateRange>('any');
	let filtersOpen = $state(false);

	let items = $state<ActivityItem[]>([]);
	let months = $state<ActivityMonth[]>([]);
	let pockets = $state<readonly Pocket[]>([]);
	let nextCursor = $state<string | null>(null);
	let loading = $state(false);
	let loadingMore = $state(false);
	let failure = $state<string | null>(null);
	let reference = $state<string | null>(null);
	let loaded = $state(false);

	let detail = $state<TransactionDetail | null>(null);
	let detailError = $state<string | null>(null);
	let wide = $state(true);

	const selected = $derived(page.url.searchParams.get('tx'));
	const groups = $derived(groupByMonth(items, months, tz));
	const filtered = $derived(
		appliedQuery !== '' ||
			direction !== 'all' ||
			currency !== 'all' ||
			status !== 'any' ||
			pocketId !== 'all' ||
			range !== 'any'
	);

	$effect(() => {
		const media = window.matchMedia('(min-width: 1024px)');
		wide = media.matches;
		const onChange = () => (wide = media.matches);
		media.addEventListener('change', onChange);
		return () => media.removeEventListener('change', onChange);
	});

	// Debounced search: the request goes out 300 ms after typing stops.
	$effect(() => {
		const value = query.trim();
		const timer = setTimeout(() => (appliedQuery = value), 300);
		return () => clearTimeout(timer);
	});

	function params(cursor: string | null): string {
		const p = new SvelteURLSearchParams({ tz });
		if (wallet) p.set('wallet', wallet);
		if (appliedQuery) p.set('q', appliedQuery);
		if (direction !== 'all') p.set('direction', direction);
		if (currency !== 'all') p.set('currency', currency);
		if (status !== 'any') p.set('status', status);
		if (pocketId !== 'all') p.set('pocketId', pocketId);
		const dates = dateRange(range, tz);
		if (dates.from) p.set('from', dates.from);
		if (dates.to) p.set('to', dates.to);
		if (cursor) p.set('cursor', cursor);
		return p.toString();
	}

	const failureOf = (exit: Exit.Exit<unknown, ApiFailure>) =>
		Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) : undefined;

	let controller: AbortController | null = null;

	async function load(more = false) {
		controller?.abort();
		const current = new AbortController();
		controller = current;
		if (more) loadingMore = true;
		else loading = true;
		const exit = await Effect.runPromiseExit(
			getJson(`/api/activity?${params(more ? nextCursor : null)}`, ActivityView, current.signal)
		);
		if (current.signal.aborted) return;
		loading = false;
		loadingMore = false;
		if (Exit.isSuccess(exit)) {
			const view = exit.value;
			if (more) {
				items = [...items, ...view.activity.items];
				const known = new Set(months.map((m) => m.month));
				months = [...months, ...view.activity.months.filter((m) => !known.has(m.month))];
			} else {
				items = [...view.activity.items];
				months = [...view.activity.months];
			}
			if (view.pockets) pockets = view.pockets;
			nextCursor = view.activity.nextCursor;
			failure = null;
			loaded = true;
			return;
		}
		const error = failureOf(exit);
		if (error?._tag === 'TransportError' && error.reason === 'aborted') return;
		failure = error?._tag === 'BackendError' ? error.message : 'Something went wrong on our side.';
		reference = error?._tag === 'BackendError' ? error.requestId : null;
	}

	// Reload the first page whenever a filter changes (and once ready).
	$effect(() => {
		void [appliedQuery, direction, currency, status, pocketId, range, wallet];
		if (shell.state.kind !== 'ready') return;
		untrack(() => void load());
	});

	$effect(() => {
		const id = selected;
		detail = null;
		detailError = null;
		if (!id || shell.state.kind !== 'ready') return;
		const current = new AbortController();
		const path = `/api/activity/${encodeURIComponent(id)}${wallet ? `?wallet=${wallet}` : ''}`;
		void Effect.runPromiseExit(getJson(path, DetailSchema, current.signal)).then((exit) => {
			if (current.signal.aborted) return;
			if (Exit.isSuccess(exit)) detail = exit.value;
			else {
				const error = failureOf(exit);
				detailError =
					error?._tag === 'BackendError' && error.code === 'not_found'
						? 'We couldn’t find that transaction.'
						: 'We couldn’t load this transaction.';
			}
		});
		return () => current.abort();
	});

	function select(id: string | null) {
		const url = new URL(page.url.href);
		if (id) url.searchParams.set('tx', id);
		else url.searchParams.delete('tx');
		void goto(url, { reset: !wide, replace: wide && !!selected });
	}

	const money = (amount: string, c: Currency, signed = false) =>
		shell.hideAmounts ? hiddenMoney(c) : formatMoney(amount, c, signed);
	const hidden = (c: Currency) => (shell.hideAmounts ? hiddenMoney(c) : null);
	const when = (iso: string, withTime: boolean) =>
		new Intl.DateTimeFormat('en-GB', {
			day: 'numeric',
			month: 'short',
			...(withTime ? { hour: '2-digit', minute: '2-digit' } : {})
		})
			.format(new Date(iso))
			.replace(' at ', ', ');
	const subtitle = (item: ActivityItem) => {
		const parts = [typeLabel(item.type), when(item.postedAt, wide)];
		if (wide && item.type === 'income') {
			parts.push(
				item.currency === 'NGN' && item.pocketCount > 1
					? `split into ${item.pocketCount} pockets`
					: `${item.currency} wallet`
			);
		}
		return parts.join(' · ');
	};

	const currencyLabel = $derived(currency === 'all' ? 'All' : currency);
	const statusText = $derived(status === 'any' ? 'Any' : statusLabel(status));
	const pocketText = $derived(
		pocketId === 'all' ? 'All' : (pockets.find((p) => p.pocketId === pocketId)?.name ?? 'All')
	);
</script>

{#snippet dropdown(
	label: string,
	value: string,
	options: ReadonlyArray<readonly [string, string]>,
	set: (v: string) => void
)}
	<DropdownMenu.Root>
		<DropdownMenu.Trigger class="filter">
			<span>{label}</span>
			<ChevronDown size={14} strokeWidth={1.8} aria-hidden="true" />
		</DropdownMenu.Trigger>
		<DropdownMenu.Portal>
			<DropdownMenu.Content class="popover filter-menu" sideOffset={8} align="start">
				<DropdownMenu.RadioGroup class="menu-group" {value} onValueChange={set}>
					{#each options as [key, text] (key)}
						<DropdownMenu.RadioItem class="menu-row" value={key}>
							{#snippet children({ checked })}
								<span class="menu-label">{text}</span>
								{#if checked}<span class="tick" aria-hidden="true">✓</span>{/if}
							{/snippet}
						</DropdownMenu.RadioItem>
					{/each}
				</DropdownMenu.RadioGroup>
			</DropdownMenu.Content>
		</DropdownMenu.Portal>
	</DropdownMenu.Root>
{/snippet}

{#snippet filterMenus()}
	{@render dropdown(
		`Currency: ${currencyLabel}`,
		currency,
		[
			['all', 'All currencies'],
			['NGN', 'NGN'],
			['USD', 'USD']
		],
		(v) => (currency = v as Currency | 'all')
	)}
	{@render dropdown(
		`Status: ${statusText}`,
		status,
		[['any', 'Any status'], ...Object.entries(STATUS_LABELS)],
		(v) => (status = v)
	)}
	{@render dropdown(
		`Pocket: ${pocketText}`,
		pocketId,
		[['all', 'All pockets'], ...pockets.map((p) => [p.pocketId, p.name] as const)],
		(v) => (pocketId = v)
	)}
	{@render dropdown(
		DATE_RANGE_LABELS[range],
		range,
		Object.entries(DATE_RANGE_LABELS),
		(v) => (range = v as DateRange)
	)}
{/snippet}

{#if !wide && selected}
	{#if detail}
		<TransactionDetailView
			{detail}
			variant="page"
			{owner}
			hideAmounts={shell.hideAmounts}
			onClose={() => history.back()}
		/>
	{:else if detailError}
		<p class="notice" role="alert">{detailError}</p>
		<button type="button" class="more" onclick={() => select(null)}>Back to activity</button>
	{:else}
		<div class="skeleton" aria-hidden="true"></div>
	{/if}
{:else}
	<div class="activity">
		<h1 class="title" tabindex="-1">{heading}</h1>
		<div class="toolbar">
			<label class="search">
				<Search size={16} strokeWidth={2} aria-hidden="true" />
				<span class="visually-hidden">Search activity</span>
				<input
					type="search"
					placeholder="Search name, reference or amount"
					bind:value={query}
					maxlength="100"
					autocomplete="off"
				/>
			</label>
			<div class="segmented" role="group" aria-label="Direction">
				{#each [['all', 'All'], ['in', 'Money in'], ['out', 'Money out']] as const as [key, text] (key)}
					<button type="button" aria-pressed={direction === key} onclick={() => (direction = key)}
						>{text}</button
					>
				{/each}
				<button
					type="button"
					class="filters-toggle"
					aria-expanded={filtersOpen}
					onclick={() => (filtersOpen = !filtersOpen)}
				>
					<SlidersHorizontal size={14} strokeWidth={2} aria-hidden="true" />Filters
				</button>
			</div>
			<div class="menus" class:open={filtersOpen}>{@render filterMenus()}</div>
		</div>

		<div class="body">
			<div class="list">
				{#if failure && !loaded}
					<RootHero pose="load-error" title="Couldn’t load activity" lead={failure} compact />
					<div class="retry">
						<button type="button" class="more" onclick={() => load()}>Try again</button>
						{#if reference}<p class="ref-note">Reference <span>{reference}</span></p>{/if}
					</div>
				{:else if !loaded}
					<div class="skeleton" aria-hidden="true"></div>
					<p class="visually-hidden" role="status">Loading activity</p>
				{:else if items.length === 0}
					<p class="empty" role="status">
						{filtered ? 'Nothing matches these filters.' : 'No activity yet.'}
					</p>
				{:else}
					{#each groups as group (group.key)}
						{@const totals = monthTotals(group.totals, hidden)}
						<section class="month" aria-label={monthLabel(group.key)}>
							<header class="month-head">
								<h2>{monthLabel(group.key)}</h2>
								<p class="totals">
									{#if totals.in}<span class="in">In {totals.in}</span>{/if}
									{#if totals.out}<span class="out">Out {totals.out}</span>{/if}
								</p>
							</header>
							<ul class="rows">
								{#each group.items as item (item.transactionId + item.currency)}
									{@const credit = isCredit(item.amount)}
									<li>
										<button
											type="button"
											class="row"
											aria-current={selected === item.transactionId ? 'true' : undefined}
											onclick={() => select(item.transactionId)}
										>
											<span class="tile" class:credit aria-hidden="true">
												{#if credit}<ArrowDown size={16} strokeWidth={2} />{:else}<ArrowUp
														size={16}
														strokeWidth={2}
													/>{/if}
											</span>
											<span class="text">
												<span class="name">{item.title ?? typeLabel(item.type)}</span>
												<span class="sub">{subtitle(item)}</span>
											</span>
											<span class="status-slot"
												><span class="pill {statusTone(item.status)}"
													>{statusLabel(item.status)}</span
												></span
											>
											<span class="figures">
												<span class="value" class:credit
													>{money(item.amount, item.currency, true)}</span
												>
												<span class="status-inline {statusTone(item.status)}"
													>{statusLabel(item.status)}</span
												>
											</span>
										</button>
									</li>
								{/each}
							</ul>
						</section>
					{/each}
					{#if nextCursor}
						<div class="retry">
							<button type="button" class="more" disabled={loadingMore} onclick={() => load(true)}
								>{loadingMore ? 'Loading…' : 'Load older activity'}</button
							>
						</div>
					{/if}
					{#if loading}<p class="visually-hidden" role="status">Updating</p>{/if}
				{/if}
			</div>

			{#if wide && selected}
				{#if detail}
					<TransactionDetailView
						{detail}
						{owner}
						hideAmounts={shell.hideAmounts}
						onClose={() => select(null)}
					/>
				{:else if detailError}
					<aside class="panel-note" role="alert">{detailError}</aside>
				{:else}
					<div class="panel-skeleton" aria-hidden="true"></div>
				{/if}
			{/if}
		</div>
	</div>
{/if}

<style>
	.activity {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	.title {
		color: var(--color-text);
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 36px;
		outline: none;
	}

	.toolbar {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.search {
		display: flex;
		align-items: center;
		gap: 10px;
		height: 44px;
		padding: 0 14px;
		border: 1px solid var(--color-border);
		border-radius: 12px;
		background: var(--color-surface);
		color: var(--color-muted);
	}

	.search input {
		flex: 1;
		min-width: 0;
		border: 0;
		outline: none;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: var(--text-14);
		line-height: 18px;
	}

	.search input::placeholder {
		color: var(--color-muted);
	}

	.search:focus-within {
		border-color: var(--color-accent);
	}

	.segmented {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
	}

	.segmented button {
		display: flex;
		align-items: center;
		gap: 6px;
		height: 36px;
		padding: 0 14px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--shell-strong, var(--color-text));
		font: inherit;
		font-size: 13px;
		line-height: var(--leading-16);
		cursor: pointer;
	}

	.segmented button[aria-pressed='true'] {
		border-color: var(--color-text);
		background: var(--color-text);
		color: var(--color-canvas);
		font-weight: var(--font-weight-semibold);
	}

	.segmented .filters-toggle {
		padding: 0 12px;
	}

	.menus {
		display: none;
		flex-wrap: wrap;
		gap: 8px;
	}

	.menus.open {
		display: flex;
	}

	:global(.filter) {
		display: flex;
		align-items: center;
		gap: 8px;
		height: 40px;
		padding: 0 12px;
		border: 1px solid var(--color-border);
		border-radius: 10px;
		background: transparent;
		color: var(--shell-strong, var(--color-text));
		font: inherit;
		font-size: 13px;
		line-height: var(--leading-16);
		white-space: nowrap;
		cursor: pointer;
	}

	:global(.popover.filter-menu) {
		min-width: 200px;
	}

	.tick {
		color: var(--color-accent);
	}

	.body {
		display: flex;
		align-items: flex-start;
		gap: 24px;
	}

	.list {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 20px;
		min-width: 0;
	}

	.month {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding-top: 8px;
	}

	.month-head {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 12px;
	}

	.month-head h2 {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.08em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.totals {
		display: none;
		gap: 16px;
		font-size: 13px;
		line-height: var(--leading-16);
	}

	.totals .in {
		color: var(--color-success);
	}

	.totals .out {
		color: var(--shell-strong, var(--color-text));
	}

	.rows {
		display: flex;
		flex-direction: column;
		padding: 4px 14px;
		border: 1px solid #ffffff14;
		border-radius: var(--radius-16);
		background: var(--color-surface);
	}

	.rows li + li .row {
		border-top: 1px solid #ffffff0f;
	}

	.row {
		display: flex;
		align-items: center;
		gap: 12px;
		width: 100%;
		height: 64px;
		padding: 0;
		border: 0;
		background: transparent;
		color: inherit;
		font: inherit;
		text-align: left;
		cursor: pointer;
	}

	.tile {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--color-text);
	}

	.tile.credit {
		background: color-mix(in oklab, var(--color-success) 16%, var(--color-surface));
		color: var(--color-success);
	}

	.text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.name {
		overflow: hidden;
		color: var(--color-text);
		font-size: var(--text-14);
		line-height: 18px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.sub {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.status-slot {
		display: none;
	}

	.figures {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		flex-shrink: 0;
		gap: 2px;
		width: 120px;
	}

	.value {
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		white-space: nowrap;
	}

	.value.credit,
	.status-inline.success {
		color: var(--color-success);
	}

	.status-inline {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.pill {
		padding: 3px 10px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--shell-strong, var(--color-text));
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.pill.success {
		background: color-mix(in oklab, var(--color-success) 16%, var(--color-surface));
		color: var(--color-success);
	}

	.empty,
	.notice {
		padding: 32px 16px;
		color: var(--color-muted);
		font-size: var(--text-14);
		text-align: center;
	}

	.retry {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 8px;
	}

	.more {
		display: flex;
		align-items: center;
		height: 40px;
		padding: 0 18px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		cursor: pointer;
	}

	.ref-note {
		color: var(--color-muted);
		font-size: 13px;
	}

	.ref-note span {
		font-family: var(--font-mono);
	}

	.skeleton {
		height: 280px;
		border-radius: var(--radius-16);
		background: var(--color-surface);
	}

	.panel-skeleton,
	.panel-note {
		flex-shrink: 0;
		width: 380px;
		min-height: 320px;
		padding: 24px;
		border-radius: var(--radius-16);
		background: var(--color-surface);
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	:global([data-theme='light']) .rows {
		border-color: var(--color-border);
	}

	@media (min-width: 1024px) {
		.activity {
			gap: 32px;
		}

		.title {
			display: none;
		}

		.toolbar {
			flex-direction: row;
			align-items: center;
		}

		.search {
			flex: 1;
			height: 40px;
			border-radius: 10px;
		}

		.segmented {
			flex-wrap: nowrap;
			gap: 2px;
			padding: 3px;
			border: 1px solid var(--color-border);
			border-radius: 10px;
			background: var(--color-surface);
		}

		.segmented button {
			height: 32px;
			padding: 0 12px;
			border: 0;
			border-radius: 7px;
			color: var(--color-muted);
		}

		.segmented button[aria-pressed='true'] {
			background: var(--color-raised);
			color: var(--color-text);
			font-weight: var(--font-weight-medium);
		}

		.segmented .filters-toggle {
			display: none;
		}

		.menus {
			display: flex;
			flex-wrap: nowrap;
			gap: 10px;
		}

		.list {
			gap: 28px;
		}

		.month {
			padding-top: 0;
		}

		.month-head {
			padding: 0 4px;
		}

		.month-head h2 {
			color: var(--color-text);
			font-family: var(--font-sans);
			font-size: var(--text-20);
			font-weight: var(--font-weight-semibold);
			letter-spacing: -0.01em;
			line-height: var(--leading-24);
			text-transform: none;
		}

		.totals {
			display: flex;
		}

		.rows {
			padding: 6px;
			border-radius: 18px;
		}

		.rows li + li .row {
			border-top-color: #ffffff0a;
		}

		.row {
			gap: 14px;
			height: 72px;
			padding: 0 14px;
			border: 1px solid transparent;
			border-radius: 12px;
		}

		.rows li + li .row[aria-current='true'],
		.row[aria-current='true'] {
			border: 1px solid #3d4446;
			background: #262b2c;
		}

		.tile {
			width: 42px;
			height: 42px;
			border-radius: 12px;
		}

		.name {
			font-size: 15px;
			font-weight: var(--font-weight-medium);
		}

		.status-slot {
			display: flex;
			flex-shrink: 0;
			width: 110px;
		}

		.figures {
			width: 140px;
		}

		.value {
			font-size: var(--text-16);
			font-weight: var(--font-weight-semibold);
			line-height: var(--leading-20);
		}

		.status-inline {
			display: none;
		}

		:global([data-theme='light']) .row[aria-current='true'] {
			border-color: var(--color-border);
			background: var(--color-raised);
		}
	}
</style>
