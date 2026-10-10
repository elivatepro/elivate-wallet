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
	import { Dialog, DropdownMenu } from 'bits-ui';
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
		TYPE_FILTERS,
		statusTone,
		typeLabel,
		type DateRange
	} from '#lib/activity.js';
	import { formatMoney, hiddenMoney } from '#lib/money.js';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import TransactionDetailView from '#lib/ui/app/TransactionDetail.svelte';

	let {
		wallet = null,
		owner = null,
		heading = 'Activity',
		canReverse = false
	}: {
		/** Managed wallet id; null for your own activity. */
		wallet?: string | null;
		/** Managed view: the owner's name for the detail copy. */
		owner?: string | null;
		heading?: string;
		/** President (W-15): a posted transaction offers "Reverse" (backend re-checks). */
		canReverse?: boolean;
	} = $props();

	const shell = getContext<Shell>('shell');
	const tz = browserTimeZone();
	/** A completed withdrawal is corrected with returned funds, never reversed (W-15). */
	const reverseHref = (d: TransactionDetail) =>
		canReverse && d.status === 'posted' && d.type !== 'withdrawal'
			? `/app/reversals?reference=${d.reference}`
			: null;

	let query = $state('');
	let appliedQuery = $state('');
	let direction = $state<'all' | 'in' | 'out'>('all');
	let currency = $state<Currency | 'all'>('all');
	let status = $state<string>('any');
	let type = $state<string>('any');
	let pocketId = $state<string>('all');
	let range = $state<DateRange | 'custom'>('any');
	let customFrom = $state('');
	let customTo = $state('');
	let sheetOpen = $state(false);
	let total = $state<number | null>(null);

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
			type !== 'any' ||
			pocketId !== 'all' ||
			range !== 'any'
	);
	/** Filters other than search and direction (the mobile "Filters · N" count). */
	const filterCount = $derived(
		[
			currency !== 'all',
			status !== 'any',
			type !== 'any',
			pocketId !== 'all',
			range !== 'any'
		].filter(Boolean).length
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

	interface Filters {
		currency: Currency | 'all';
		status: string;
		type: string;
		pocketId: string;
		range: DateRange | 'custom';
		from: string;
		to: string;
	}
	const current = (): Filters => ({
		currency,
		status,
		type,
		pocketId,
		range,
		from: customFrom,
		to: customTo
	});

	function params(cursor: string | null, f: Filters = current(), limit?: number): string {
		const p = new SvelteURLSearchParams({ tz });
		if (wallet) p.set('wallet', wallet);
		if (appliedQuery) p.set('q', appliedQuery);
		if (direction !== 'all') p.set('direction', direction);
		if (f.currency !== 'all') p.set('currency', f.currency);
		if (f.status !== 'any') p.set('status', f.status);
		if (f.type !== 'any') p.set('type', f.type);
		if (f.pocketId !== 'all') p.set('pocketId', f.pocketId);
		const dates =
			f.range === 'custom'
				? { from: f.from || undefined, to: f.to || undefined }
				: dateRange(f.range, tz);
		if (dates.from) p.set('from', dates.from);
		if (dates.to) p.set('to', dates.to);
		if (cursor) p.set('cursor', cursor);
		if (limit) p.set('limit', String(limit));
		return p.toString();
	}

	function clearFilters() {
		currency = 'all';
		status = 'any';
		type = 'any';
		pocketId = 'all';
		range = 'any';
		customFrom = '';
		customTo = '';
	}

	// ── Mobile filter sheet (Q01): edits a draft, previews the count, applies on "Show". ──
	let draft = $state<Filters>({
		currency: 'all',
		status: 'any',
		type: 'any',
		pocketId: 'all',
		range: 'any',
		from: '',
		to: ''
	});
	let preview = $state<number | null>(null);
	function openSheet() {
		draft = current();
		preview = total;
		sheetOpen = true;
	}
	$effect(() => {
		if (!sheetOpen) return;
		const f = { ...draft };
		const ctrl = new AbortController();
		const timer = setTimeout(() => {
			void Effect.runPromiseExit(
				getJson(`/api/activity?${params(null, f, 1)}`, ActivityView, ctrl.signal)
			).then((exit) => {
				if (!ctrl.signal.aborted && Exit.isSuccess(exit))
					preview = exit.value.activity.total ?? null;
			});
		}, 200);
		return () => {
			clearTimeout(timer);
			ctrl.abort();
		};
	});
	function applySheet() {
		currency = draft.currency;
		status = draft.status;
		type = draft.type;
		pocketId = draft.pocketId;
		range = draft.range;
		customFrom = draft.from;
		customTo = draft.to;
		sheetOpen = false;
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
			if (!more) total = view.activity.total ?? null;
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
		void [
			appliedQuery,
			direction,
			currency,
			status,
			type,
			pocketId,
			range,
			customFrom,
			customTo,
			wallet
		];
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
		if (item.reversedAt) parts.push(`reversed ${when(item.reversedAt, false)}`);
		else if (wide && item.type === 'income') {
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
	const noMatchText = $derived.by(() => {
		const what = currency === 'all' ? 'activity' : `${currency} activity`;
		return appliedQuery
			? `No ${what} matches “${appliedQuery}”.`
			: `No ${what} matches these filters.`;
	});
	const typeText = $derived(type === 'any' ? 'Any' : typeLabel(type));
	const rangeText = $derived(range === 'custom' ? 'Chosen dates' : DATE_RANGE_LABELS[range]);
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
		`Type: ${typeText}`,
		type,
		[['any', 'Any type'], ...Object.entries(TYPE_FILTERS)],
		(v) => (type = v)
	)}
	{@render dropdown(
		`Pocket: ${pocketText}`,
		pocketId,
		[['all', 'All pockets'], ...pockets.map((p) => [p.pocketId, p.name] as const)],
		(v) => (pocketId = v)
	)}
	{@render dropdown(
		rangeText,
		range,
		[...Object.entries(DATE_RANGE_LABELS), ['custom', 'Pick dates']],
		(v) => (range = v as DateRange | 'custom')
	)}
{/snippet}

{#if !wide && selected}
	{#if detail}
		<TransactionDetailView
			{detail}
			variant="page"
			{owner}
			reverseHref={reverseHref(detail)}
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
					class:active={filterCount > 0}
					aria-haspopup="dialog"
					onclick={openSheet}
				>
					<SlidersHorizontal size={14} strokeWidth={2} aria-hidden="true" />Filters{filterCount
						? ` · ${filterCount}`
						: ''}
				</button>
			</div>
			<div class="menus">{@render filterMenus()}</div>
		</div>
		{#if range === 'custom'}
			<div class="custom-dates">
				<label>From <input type="date" bind:value={customFrom} max={customTo || undefined} /></label
				>
				<label>To <input type="date" bind:value={customTo} min={customFrom || undefined} /></label>
			</div>
		{/if}

		<div class="body">
			<div class="list">
				{#if failure && !loaded}
					<RootHero pose="load-error" title="Couldn’t load activity" lead={failure} compact />
					<div class="retry">
						<button type="button" class="more" onclick={() => load()}>Try again</button>
						{#if reference}<p class="ref-note">Reference <span>{reference}</span></p>{/if}
					</div>
				{:else if failure}
					<div class="retry" role="alert">
						<p class="ref-note">We couldn’t apply these filters. {failure}</p>
						<button type="button" class="more" onclick={() => load()}>Try again</button>
					</div>
				{:else if !loaded}
					<div class="skeleton" aria-hidden="true"></div>
					<p class="visually-hidden" role="status">Loading activity</p>
				{:else if items.length === 0 && filtered}
					<section class="no-match" aria-labelledby="no-match-title">
						<div class="nm-art" aria-hidden="true">
							<div class="nm-shade"></div>
							<div class="nm-grain"></div>
							<RootImage pose="no-matches" class="nm-root" sizes="190px" />
						</div>
						<h2 id="no-match-title" class="nm-title">Nothing matches</h2>
						<p class="nm-lead" role="status">{noMatchText}</p>
						<div class="nm-actions">
							{#if appliedQuery}<button type="button" class="nm-ghost" onclick={() => (query = '')}
									>Clear search</button
								>{/if}
							{#if filterCount > 0 || direction !== 'all'}
								<button
									type="button"
									class="nm-primary"
									onclick={() => {
										clearFilters();
										direction = 'all';
									}}>Clear filters</button
								>
							{/if}
						</div>
					</section>
				{:else if items.length === 0}
					<p class="empty" role="status">No activity yet.</p>
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
													>{item.movedAmount
														? money(item.movedAmount, item.currency)
														: money(item.amount, item.currency, true)}</span
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
							<button
								type="button"
								class="more"
								disabled={loadingMore || loading}
								onclick={() => load(true)}
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
						reverseHref={reverseHref(detail)}
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

<Dialog.Root bind:open={sheetOpen}>
	<Dialog.Portal>
		<Dialog.Overlay class="sheet-overlay" />
		<Dialog.Content class="sheet">
			<span class="sheet-handle" aria-hidden="true"></span>
			<div class="sheet-head">
				<Dialog.Title class="sheet-title">Filters</Dialog.Title>
				<button
					type="button"
					class="sheet-clear"
					onclick={() =>
						(draft = {
							currency: 'all',
							status: 'any',
							type: 'any',
							pocketId: 'all',
							range: 'any',
							from: '',
							to: ''
						})}>Clear all</button
				>
			</div>
			<div class="sheet-body">
				<fieldset>
					<legend>Currency</legend>
					<div class="seg3">
						{#each [['all', 'All'], ['NGN', 'NGN'], ['USD', 'USD']] as const as [key, text] (key)}
							<button
								type="button"
								aria-pressed={draft.currency === key}
								onclick={() => (draft.currency = key)}>{text}</button
							>
						{/each}
					</div>
				</fieldset>
				{@render chipGroup(
					'Status',
					draft.status,
					[['any', 'Any'], ...Object.entries(STATUS_LABELS)],
					(v) => (draft.status = v)
				)}
				{@render chipGroup(
					'Type',
					draft.type,
					[['any', 'Any'], ...Object.entries(TYPE_FILTERS)],
					(v) => (draft.type = v)
				)}
				{@render chipGroup(
					'Pocket',
					draft.pocketId,
					[['all', 'All'], ...pockets.map((p) => [p.pocketId, p.name] as const)],
					(v) => (draft.pocketId = v)
				)}
				{@render chipGroup(
					'Date',
					draft.range,
					[
						['any', 'Any time'],
						['this_month', 'This month'],
						['last_3_months', 'Last 3 months'],
						['custom', 'Pick dates']
					],
					(v) => (draft.range = v as DateRange | 'custom')
				)}
				{#if draft.range === 'custom'}
					<div class="custom-dates">
						<label>From <input type="date" bind:value={draft.from} /></label>
						<label>To <input type="date" bind:value={draft.to} /></label>
					</div>
				{/if}
			</div>
			<button type="button" class="sheet-show" onclick={applySheet}
				>{preview === null
					? 'Show results'
					: `Show ${preview} result${preview === 1 ? '' : 's'}`}</button
			>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

{#snippet chipGroup(
	label: string,
	value: string,
	options: ReadonlyArray<readonly [string, string]>,
	set: (v: string) => void
)}
	<fieldset>
		<legend>{label}</legend>
		<div class="chips">
			{#each options as [key, text] (key)}
				<button type="button" aria-pressed={value === key} onclick={() => set(key)}>{text}</button>
			{/each}
		</div>
	</fieldset>
{/snippet}

<style>
	.filters-toggle.active {
		border-color: #4a5254;
		background: #2b3031;
	}

	.custom-dates {
		display: flex;
		flex-wrap: wrap;
		gap: 12px;
		color: var(--color-muted);
		font-size: 13px;
	}

	.custom-dates label {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.custom-dates input {
		height: 40px;
		padding: 0 10px;
		border: 1px solid var(--color-border);
		border-radius: 10px;
		background: var(--color-surface);
		color: var(--color-text);
		font: inherit;
		color-scheme: dark;
	}

	/* ── Q02 no matches ── */
	.no-match {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 10px;
		padding-top: 8px;
		text-align: center;
	}

	.nm-art {
		position: relative;
		display: flex;
		justify-content: center;
		align-self: stretch;
		height: 230px;
		margin-bottom: 14px;
		overflow: clip;
		border-radius: 24px;
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 50% / cover;
	}

	.nm-shade,
	.nm-grain {
		position: absolute;
		inset: 0;
	}

	.nm-shade {
		background-image: linear-gradient(
			in oklab 180deg,
			oklab(21.5% -0.004 -0.003 / 0%) 30%,
			oklab(21.5% -0.004 -0.003 / 85%) 100%
		);
	}

	.nm-grain {
		background: url('/auth-bg/grain-256.png') 50% / 256px 256px;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}

	.nm-art :global(.nm-root) {
		position: absolute;
		bottom: -10px;
		width: 180px;
		height: 242px;
	}

	.nm-title {
		color: var(--color-text);
		font-size: 26px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 32px;
	}

	.nm-lead {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: 20px;
	}

	.nm-actions {
		display: flex;
		gap: 10px;
		align-self: stretch;
		padding-top: 14px;
	}

	.nm-actions button {
		flex: 1;
		height: 48px;
		padding: 0 22px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.nm-ghost {
		border: 1px solid var(--color-border);
		background: transparent;
		color: var(--color-text);
	}

	.nm-primary {
		border: 0;
		background: var(--color-text);
		color: var(--color-canvas);
	}

	/* ── Q01 mobile filter sheet ── */
	:global(.sheet-overlay) {
		position: fixed;
		inset: 0;
		z-index: 20;
		background: #000000a8;
	}

	:global(.sheet) {
		position: fixed;
		left: 0;
		right: 0;
		bottom: 0;
		z-index: 21;
		display: flex;
		flex-direction: column;
		gap: 16px;
		max-height: 88dvh;
		padding: 10px 20px calc(24px + env(safe-area-inset-bottom));
		overflow-y: auto;
		border-radius: 24px 24px 0 0;
		background: var(--color-surface);
		color: var(--color-text);
	}

	.sheet-handle {
		align-self: center;
		width: 40px;
		height: 5px;
		border-radius: var(--radius-pill);
		background: #3d4446;
	}

	.sheet-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
	}

	:global(.sheet-title) {
		font-size: 22px;
		font-weight: var(--font-weight-semibold);
		line-height: 28px;
	}

	.sheet-clear {
		border: 0;
		background: transparent;
		color: var(--color-accent);
		font: inherit;
		font-size: 15px;
		cursor: pointer;
	}

	.sheet-body {
		display: flex;
		flex-direction: column;
		gap: 18px;
	}

	fieldset {
		display: flex;
		flex-direction: column;
		gap: 10px;
		border: 0;
	}

	legend {
		margin-bottom: 10px;
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
	}

	.seg3 {
		display: flex;
		padding: 4px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: var(--color-canvas);
	}

	.seg3 button {
		flex: 1;
		height: 38px;
		border: 1px solid transparent;
		border-radius: 10px;
		background: transparent;
		color: var(--color-muted);
		font: inherit;
		font-size: var(--text-14);
		cursor: pointer;
	}

	.seg3 button[aria-pressed='true'],
	.chips button[aria-pressed='true'] {
		border-color: #4a5254;
		background: #2b3031;
		color: var(--color-text);
		font-weight: var(--font-weight-semibold);
	}

	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
	}

	.chips button {
		height: 36px;
		padding: 0 14px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--shell-strong, var(--color-text));
		font: inherit;
		font-size: 13px;
		cursor: pointer;
	}

	.sheet-show {
		flex-shrink: 0;
		height: 54px;
		border: 0;
		border-radius: var(--radius-pill);
		background-image: var(--button-primary-bg);
		color: var(--button-primary-ink, #14100e);
		font: inherit;
		font-size: 16px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.pill.danger {
		background: color-mix(in oklab, var(--color-danger) 16%, var(--color-surface));
		color: var(--color-danger);
	}

	.status-inline.danger {
		color: var(--color-danger);
	}

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

		.nm-art {
			align-self: center;
			width: 640px;
			height: 250px;
		}

		.nm-title {
			font-size: 36px;
			line-height: 44px;
		}

		.nm-lead {
			font-size: 15px;
		}

		.nm-actions {
			align-self: center;
		}

		.nm-actions button {
			flex: none;
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
