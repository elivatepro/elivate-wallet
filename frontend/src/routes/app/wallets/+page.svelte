<!--
	Member wallets for leaders (W-07 managed wallets; owner decisions
	2026-10-08). Paper "App — Screens v4" Q04 (list: people, status, available
	per currency, never mixed) and Q05 (one wallet: available / posted /
	reserved per currency and the per-pocket breakdown, recent activity).
	?wallet=<id> opens a wallet; &view=activity shows its full activity with the
	M03 composition. The backend authorizes every segment; never your own.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Search from '@lucide/svelte/icons/search';
	import { MemberWalletView } from '#lib/contract/app.js';
	import { UUID_PATTERN } from '#lib/contract/common.js';
	import type { ApiFailure } from '#lib/contract/errors.js';
	import { ManagedWalletPage, type Currency } from '#lib/contract/ledger.js';
	import { getJson } from '#lib/client/api.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { initials, isCredit, typeLabel } from '#lib/activity.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import { formatMoney, hiddenMoney, isZero } from '#lib/money.js';
	import ActivityBrowser from '#lib/ui/app/ActivityBrowser.svelte';
	import CurrencySwitch from '#lib/ui/app/CurrencySwitch.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';

	const shell = getContext<Shell>('shell');
	/** Navigation hints only; the backend authorizes every command. */
	const can = (permission: string) =>
		shell.state.kind === 'ready' &&
		(shell.state.view.capabilities?.permissions ?? []).includes(permission);
	const DOTS = ['#ff7f4f', '#43c48b', '#82b8e8', '#f2b85e', '#a9b0b3', '#c9a3ff'];

	const walletParam = $derived(page.url.searchParams.get('wallet'));
	const wallet = $derived(walletParam && UUID_PATTERN.test(walletParam) ? walletParam : null);
	const showActivity = $derived(page.url.searchParams.get('view') === 'activity');

	const money = (amount: string, c: Currency) =>
		shell.hideAmounts ? hiddenMoney(c) : formatMoney(amount, c);
	const failureText = (exit: Exit.Exit<unknown, ApiFailure>, fallback: string) => {
		const failure = Exit.isFailure(exit)
			? Option.getOrUndefined(Cause.findErrorOption(exit.cause))
			: undefined;
		return failure?._tag === 'BackendError' ? failure.message : fallback;
	};

	// ── Q04 list ──
	let query = $state('');
	let applied = $state('');
	let list = $state<ManagedWalletPage | null>(null);
	let items = $state<ManagedWalletPage['items'][number][]>([]);
	let listError = $state<string | null>(null);

	$effect(() => {
		const value = query.trim();
		const timer = setTimeout(() => (applied = value), 300);
		return () => clearTimeout(timer);
	});

	let listCtrl: AbortController | null = null;
	async function loadList(more = false) {
		listCtrl?.abort();
		const ctrl = new AbortController();
		listCtrl = ctrl;
		const p = new SvelteURLSearchParams();
		if (applied) p.set('q', applied);
		if (more && list?.nextCursor) p.set('cursor', list.nextCursor);
		const exit = await Effect.runPromiseExit(
			getJson(`/api/wallets?${p}`, ManagedWalletPage, ctrl.signal)
		);
		if (ctrl.signal.aborted) return;
		if (Exit.isSuccess(exit)) {
			items = more ? [...items, ...exit.value.items] : [...exit.value.items];
			list = exit.value;
			listError = null;
			return;
		}
		listError = failureText(exit, 'We couldn’t load the wallets.');
	}

	$effect(() => {
		void applied;
		if (shell.state.kind === 'ready' && !wallet) void loadList();
	});

	const cell = (item: ManagedWalletPage['items'][number], c: Currency) => {
		const totals = item.currencies.find((x) => x.currency === c);
		return totals ? money(totals.available, c) : '—';
	};
	const scopeLine = $derived(
		list?.scope
			? list.scope.kind === 'network'
				? `Everyone in ${list.scope.name}`
				: `${list.scope.name} and everything below`
			: ''
	);

	// ── Q05 one wallet ──
	let view = $state<MemberWalletView | null>(null);
	let viewError = $state<string | null>(null);
	let chosen = $state<Currency | null>(null);

	$effect(() => {
		const id = wallet;
		view = null;
		viewError = null;
		if (!id || shell.state.kind !== 'ready') return;
		const ctrl = new AbortController();
		void Effect.runPromiseExit(getJson(`/api/wallets/${id}`, MemberWalletView, ctrl.signal)).then(
			(exit) => {
				if (ctrl.signal.aborted) return;
				if (Exit.isSuccess(exit)) view = exit.value;
				else viewError = failureText(exit, 'We couldn’t load this wallet.');
			}
		);
		return () => ctrl.abort();
	});

	const person = $derived(view?.wallet.person ?? null);
	const name = $derived(person?.name ?? person?.uid ?? 'Member');
	const firstName = $derived(person?.name?.split(' ')[0] ?? name);
	const membership = $derived(view?.wallet.memberships?.[0] ?? null);
	/** "Convert" next to Move (owner decision 2026-10-09) and "Adjust", for an active membership. */
	const actionFor = $derived(
		view?.wallet.memberships?.find((m) => m.status === 'active' && m.membershipId)?.membershipId ??
			null
	);
	const canConvert = $derived(!!actionFor && can('perform_currency_conversion'));
	const canAdjust = $derived(!!actionFor && can('manual_credit_debit_adjustment'));
	const subtitle = $derived(
		[person?.uid, membership ? ROLE_LABELS[membership.role] : null, membership?.officeName]
			.filter(Boolean)
			.join(' · ')
	);
	const currencies = $derived<Currency[]>(view?.network?.currencies.map((c) => c.currency) ?? []);
	const currency = $derived<Currency | null>(
		chosen && currencies.includes(chosen) ? chosen : (currencies[0] ?? null)
	);
	const setCurrency = (c: Currency) => (chosen = c);
	const balance = $derived(view?.network?.currencies.find((c) => c.currency === currency) ?? null);
	const pocketRows = $derived(
		(view?.network?.pockets ?? []).map((p, i) => {
			const line = balance?.pockets?.find((b) => b.pocketId === p.pocketId);
			return {
				...p,
				dot: p.kind === 'debt' ? '#f57875' : DOTS[i % DOTS.length],
				posted: line?.posted ?? '0.00',
				available: line?.available ?? '0.00'
			};
		})
	);
	const day = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short' }).format(new Date(iso));
	const activityHref = $derived(
		wallet ? `/app/wallets?wallet=${wallet}&view=activity` : '/app/wallets'
	);
	const last = $derived(view?.recent[0] ?? null);
</script>

<svelte:head><title>Member wallets · Elivate Wallet</title></svelte:head>

{#snippet hero(pose: 'member-wallets' | 'member-wallet', title: string, line: string)}
	<section class="hero" aria-labelledby="hero-title">
		<div class="hero-shade" aria-hidden="true"></div>
		<div class="hero-grain" aria-hidden="true"></div>
		<RootImage {pose} class="hero-root" sizes="180px" eager />
		<div class="hero-text">
			<h1 id="hero-title" tabindex="-1">{title}</h1>
			{#if line}<p>{line}</p>{/if}
		</div>
	</section>
{/snippet}

{#if wallet && showActivity}
	<a class="back" href="/app/wallets?wallet={wallet}"
		><ChevronLeft size={18} strokeWidth={2} aria-hidden="true" />{person ? name : 'Wallet'}</a
	>
	<ActivityBrowser
		{wallet}
		owner={person?.name ?? null}
		heading={`${firstName}’s activity`}
		canReverse={can('reverse_transaction')}
	/>
{:else if wallet}
	<a class="back mobile-only" href="/app/wallets"
		><ChevronLeft size={18} strokeWidth={2} aria-hidden="true" />Member wallets</a
	>
	{#if viewError}
		<RootHero pose="load-error" title="Couldn’t load this wallet" lead={viewError} compact />
	{:else if !view}
		<div class="skeleton" aria-hidden="true"></div>
		<p class="visually-hidden" role="status">Loading the wallet</p>
	{:else}
		<div class="desktop-only">{@render hero('member-wallet', name, subtitle)}</div>

		<!-- Q05 mobile hero card -->
		<section class="card-hero mobile-only" aria-label="{name}: available">
			<div class="ch-shade" aria-hidden="true"></div>
			<RootImage pose="member-wallet" class="ch-root" sizes="110px" eager />
			<div class="ch-top">
				<span class="ch-label">{firstName} · available</span>
				{#if currencies.length > 1 && currency}
					<CurrencySwitch {currencies} bind:currency={() => currency!, setCurrency} size="sm" />
				{/if}
			</div>
			{#if balance && currency}
				<p class="ch-amount">{money(balance.available, currency)}</p>
				<div class="ch-chips">
					<span class="ch-chip">Posted {money(balance.posted, currency)}</span>
					<span class="ch-chip warn">Reserved {money(balance.reserved, currency)}</span>
				</div>
			{:else}
				<p class="ch-amount">No money here yet</p>
			{/if}
		</section>

		{#if balance && currency}
			<section class="strip desktop-only" aria-label="Balances">
				<div class="kpi">
					<span class="kpi-label">Available · {currency}</span>
					<span class="kpi-main">{money(balance.available, currency)}</span>
				</div>
				<div class="kpi">
					<span class="kpi-label">Posted</span>
					<span class="kpi-value">{money(balance.posted, currency)}</span>
				</div>
				<div class="kpi">
					<span class="kpi-label">Reserved</span>
					<span class="kpi-value warn">{money(balance.reserved, currency)}</span>
				</div>
				{#if currencies.length > 1}
					<div class="kpi-switch">
						<CurrencySwitch {currencies} bind:currency={() => currency!, setCurrency} />
					</div>
				{/if}
			</section>
		{/if}

		{#if canConvert || canAdjust}
			<div class="w-actions">
				{#if canConvert}<a class="w-action" href={`/app/convert?member=${actionFor}`}>Convert</a
					>{/if}
				{#if canAdjust}<a class="w-action" href={`/app/adjust?member=${actionFor}`}>Adjust</a>{/if}
			</div>
		{/if}

		<div class="lower">
			<section class="card pockets" aria-label="Pockets">
				<div class="thead">
					<span class="grow">Pocket</span><span class="num desktop-only">Posted</span><span
						class="num">Available</span
					>
				</div>
				<ul>
					{#each pocketRows as p (p.pocketId)}
						<li>
							<span class="grow pocket"
								><span class="dot" style:background={p.dot} aria-hidden="true"></span>{p.name}</span
							>
							{#if currency}
								<span class="num muted desktop-only">{money(p.posted, currency)}</span>
								<span class="num strong" class:faint={p.kind === 'debt'}
									>{p.kind === 'debt'
										? isZero(p.posted)
											? '—'
											: money(p.posted, currency)
										: money(p.available, currency)}</span
								>
							{/if}
						</li>
					{/each}
				</ul>
			</section>

			<section class="card recent desktop-only" aria-labelledby="recent-title">
				<header>
					<h2 id="recent-title">Recent activity</h2>
					<a href={activityHref}>View all</a>
				</header>
				{#if view.recent.length === 0}
					<p class="none">No activity yet.</p>
				{:else}
					<ul>
						{#each view.recent as item (item.transactionId + item.currency)}
							<li>
								<a href="{activityHref}&tx={item.transactionId}">
									<span class="r-text"
										><span class="r-title"
											>{item.title ? `${item.title} · ` : ''}{typeLabel(item.type)}</span
										><span class="r-sub">{day(item.postedAt)} · {item.reference}</span></span
									>
									<span class="r-amount" class:credit={isCredit(item.amount)}
										>{shell.hideAmounts
											? hiddenMoney(item.currency)
											: formatMoney(item.amount, item.currency, true)}</span
									>
								</a>
							</li>
						{/each}
					</ul>
				{/if}
			</section>

			<a class="their-activity mobile-only" href={activityHref}>
				<span class="ta-text"
					><span class="ta-title">{firstName}’s activity</span>{#if last}<span class="ta-sub"
							>Last: {last.title ?? typeLabel(last.type)} · {shell.hideAmounts
								? hiddenMoney(last.currency)
								: formatMoney(last.amount, last.currency, true)} · {day(last.postedAt)}</span
						>{/if}</span
				>
				<ChevronRight size={16} strokeWidth={2} aria-hidden="true" />
			</a>
		</div>
	{/if}
{:else}
	<h1 class="title mobile-only">Member wallets</h1>
	{#if list}
		<div class="list-hero">
			{@render hero(
				'member-wallets',
				`${list.people ?? items.length} ${(list.people ?? items.length) === 1 ? 'person' : 'people'}`,
				scopeLine
			)}
		</div>
	{/if}
	<label class="search">
		<Search size={16} strokeWidth={2} aria-hidden="true" />
		<span class="visually-hidden">Search members</span>
		<input type="search" placeholder="Search name or UID" bind:value={query} maxlength="100" />
	</label>
	{#if listError}
		<p class="notice" role="alert">{listError}</p>
	{:else if !list}
		<div class="skeleton" aria-hidden="true"></div>
	{:else if items.length === 0}
		<p class="notice" role="status">
			{applied ? 'No member matches that search.' : 'No member wallets to show here.'}
		</p>
	{:else}
		<div class="table">
			<div class="thead desktop-only" aria-hidden="true">
				<span class="grow">Member</span><span class="col">Status</span><span class="col">NGN</span
				><span class="col wide">USD</span><span class="chev"></span>
			</div>
			<ul>
				{#each items as item (item.walletId)}
					{@const suspended = item.status === 'suspended'}
					<li>
						<a class="row" href="/app/wallets?wallet={item.walletId}">
							<span class="grow who">
								<span class="avatar" aria-hidden="true"
									>{initials(item.person?.name, item.person?.uid ?? '')}</span
								>
								<span class="who-text">
									<span class="name"
										>{item.person?.name ?? item.person?.uid ?? 'Member'}{#if suspended}<span
												class="mobile-only"
											>
												· Suspended</span
											>{/if}</span
									>
									<span class="uid desktop-only">{item.person?.uid}</span>
									<span class="amounts mobile-only"
										>{item.currencies.map((c) => money(c.available, c.currency)).join(' · ') ||
											'—'}</span
									>
								</span>
							</span>
							<span class="col desktop-only">
								{#if item.status}<span
										class="pill"
										class:danger={suspended}
										class:ended={item.status === 'ended'}
										>{item.status === 'active' ? 'Active' : suspended ? 'Suspended' : 'Left'}</span
									>{/if}
							</span>
							<span class="col money desktop-only">{cell(item, 'NGN')}</span>
							<span class="col wide money desktop-only">{cell(item, 'USD')}</span>
							<span class="chev" aria-hidden="true"><ChevronRight size={16} strokeWidth={2} /></span
							>
						</a>
					</li>
				{/each}
			</ul>
		</div>
		{#if list.nextCursor}<button type="button" class="more" onclick={() => loadList(true)}
				>Load more</button
			>{/if}
	{/if}
{/if}

<style>
	.w-actions {
		display: flex;
		gap: 10px;
		margin-top: 16px;
	}

	.w-action {
		display: inline-flex;
		align-items: center;
		height: 40px;
		padding: 0 18px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		color: var(--color-text);
		font-size: 14px;
		font-weight: var(--font-weight-medium);
		text-decoration: none;
	}

	.w-action:hover {
		border-color: var(--color-accent);
	}

	.desktop-only {
		display: none;
	}

	.title {
		color: var(--color-text);
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 36px;
	}

	.back {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		min-height: var(--hit-min);
		color: var(--color-text);
		font-size: 17px;
		font-weight: var(--font-weight-medium);
		text-decoration: none;
	}

	.skeleton {
		height: 220px;
		border-radius: 24px;
		background: var(--color-surface);
	}

	/* ── Hero (Q04 / Q05) ── */
	.hero {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: flex-start;
		height: 156px;
		padding: 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 22px;
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 50% 30% / cover;
		background-origin: border-box;
	}

	.hero-shade,
	.hero-grain {
		position: absolute;
		inset: 0;
	}

	.hero-shade {
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(18.5% -0.002 -0.003 / 92%) 0%,
			oklab(18.5% -0.002 -0.003 / 55%) 55%,
			oklab(18.5% -0.002 -0.003 / 0%) 100%
		);
	}

	.hero-grain {
		background: url('/auth-bg/grain-256.png') 50% / 256px 256px repeat;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}

	.hero :global(.hero-root) {
		position: absolute;
		right: 16px;
		bottom: -12px;
		width: 110px;
		height: 148px;
	}

	.hero-text {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 6px;
		max-width: 60%;
	}

	.hero-text h1 {
		color: #f2f4f4;
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 34px;
		outline: none;
	}

	.hero-text p {
		color: #a9b0b3;
		font-size: 13px;
		line-height: 18px;
	}

	/* ── Search ── */
	.search {
		display: flex;
		align-items: center;
		gap: 10px;
		height: 44px;
		padding: 0 14px;
		border: 1px solid #2a2f31;
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
	}

	/* ── Q04 list ── */
	.table {
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 18px;
		background: var(--color-surface);
	}

	.table li + li .row {
		border-top: 1px solid #ffffff0a;
	}

	.row {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 64px;
		padding: 0 18px;
		color: var(--color-text);
		text-decoration: none;
	}

	.grow {
		flex: 1;
		min-width: 0;
	}

	.who {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	.avatar {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		border-radius: var(--radius-pill);
		background: #2c3133;
		color: #f2f4f4;
		font-size: var(--text-12);
		font-weight: var(--font-weight-semibold);
	}

	.who-text {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.name {
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.uid,
	.amounts {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: 16px;
	}

	.chev {
		display: flex;
		justify-content: center;
		flex-shrink: 0;
		width: 32px;
		color: var(--color-muted);
	}

	.pill {
		display: inline-flex;
		padding: 3px 10px;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--color-success) 16%, var(--color-surface));
		color: var(--color-success);
		font-size: var(--text-12);
		line-height: 16px;
	}

	.pill.danger {
		background: color-mix(in oklab, var(--color-danger) 16%, var(--color-surface));
		color: var(--color-danger);
	}

	.pill.ended {
		background: var(--color-raised);
		color: var(--color-muted);
	}

	.notice {
		padding: 24px 0;
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	.more {
		align-self: center;
		height: 40px;
		padding: 0 18px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 13px;
		cursor: pointer;
	}

	/* ── Q05 mobile hero card ── */
	.card-hero {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 14px;
		padding: 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 22px;
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 80% / cover;
		background-origin: border-box;
		color: #f2f4f4;
	}

	.ch-shade {
		position: absolute;
		inset: 0;
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(21.5% -0.004 -0.003 / 95%) 0%,
			oklab(21.5% -0.004 -0.003 / 70%) 60%,
			oklab(21.5% -0.004 -0.003 / 20%) 100%
		);
	}

	.card-hero :global(.ch-root) {
		position: absolute;
		right: -4px;
		bottom: -12px;
		width: 110px;
		height: 148px;
	}

	.ch-top {
		position: relative;
		display: flex;
		align-items: center;
		justify-content: space-between;
	}

	.ch-label {
		color: #d5dadb;
		font-size: 13px;
	}

	.ch-amount {
		position: relative;
		font-size: 30px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.03em;
		line-height: 36px;
	}

	.ch-chips {
		position: relative;
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 6px;
	}

	.ch-chip {
		padding: 5px 10px;
		border: 1px solid #ffffff1a;
		border-radius: var(--radius-pill);
		background: #1113148c;
		font-size: var(--text-12);
		line-height: 16px;
	}

	.ch-chip.warn {
		color: #f2b85e;
	}

	/* ── Pockets / recent ── */
	.lower {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.card {
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 18px;
		background: var(--color-surface);
	}

	.thead {
		display: flex;
		align-items: center;
		height: 42px;
		padding: 0 20px;
		border-bottom: 1px solid #2a2f31;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 11px;
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	.pockets li {
		display: flex;
		align-items: center;
		min-height: 52px;
		padding: 0 20px;
		font-size: var(--text-14);
	}

	.pockets li + li {
		border-top: 1px solid #22272a;
	}

	.pocket {
		display: flex;
		align-items: center;
		gap: 10px;
		color: var(--color-text);
	}

	.dot {
		flex-shrink: 0;
		width: 8px;
		height: 8px;
		border-radius: var(--radius-pill);
	}

	.num {
		flex-shrink: 0;
		width: 150px;
		text-align: right;
	}

	.muted {
		color: #d5dadb;
	}

	.strong {
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.faint {
		color: var(--color-muted);
		font-weight: var(--font-weight-regular);
	}

	.recent header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		height: 52px;
		padding: 0 20px;
		border-bottom: 1px solid #2a2f31;
	}

	.recent h2 {
		color: var(--color-text);
		font-size: var(--text-16);
		font-weight: var(--font-weight-semibold);
	}

	.recent header a {
		color: var(--color-accent);
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		text-decoration: none;
	}

	.recent li + li a {
		border-top: 1px solid #22272a;
	}

	.recent li a {
		display: flex;
		align-items: center;
		gap: 12px;
		height: 62px;
		padding: 0 20px;
		color: inherit;
		text-decoration: none;
	}

	.r-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
	}

	.r-title {
		color: var(--color-text);
		font-size: var(--text-14);
	}

	.r-sub {
		color: var(--color-muted);
		font-size: var(--text-12);
	}

	.r-amount {
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
	}

	.r-amount.credit {
		color: var(--color-success);
	}

	.none {
		padding: 20px;
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	.their-activity {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 16px 18px;
		border: 1px solid #ffffff14;
		border-radius: 18px;
		background: var(--color-surface);
		color: var(--color-muted);
		text-decoration: none;
	}

	.ta-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
	}

	.ta-title {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
	}

	.ta-sub {
		font-size: var(--text-12);
	}

	:global([data-theme='light']) .hero,
	:global([data-theme='light']) .table,
	:global([data-theme='light']) .card,
	:global([data-theme='light']) .their-activity {
		border-color: var(--color-border);
	}

	@media (min-width: 1024px) {
		.desktop-only {
			display: revert;
		}

		.mobile-only {
			display: none;
		}

		.hero {
			justify-content: space-between;
			height: 220px;
			padding: 32px;
			border-radius: 24px;
		}

		.hero :global(.hero-root) {
			right: 64px;
			bottom: -14px;
			width: 180px;
			height: 242px;
		}

		.hero-text h1 {
			font-size: 40px;
			line-height: 44px;
		}

		.hero-text p {
			font-size: 15px;
			line-height: 20px;
		}

		.search {
			width: 340px;
			height: 42px;
		}

		.table .thead {
			display: flex;
			gap: 16px;
			border-bottom-color: #ffffff0f;
		}

		.row {
			gap: 16px;
			padding: 0 20px;
		}

		.col {
			flex-shrink: 0;
			width: 140px;
		}

		.col.wide {
			width: 180px;
		}

		.money {
			font-size: var(--text-14);
			font-weight: var(--font-weight-medium);
		}

		.name {
			font-size: var(--text-14);
		}

		.avatar {
			display: flex;
		}

		.strip {
			display: flex;
			border: 1px solid #ffffff14;
			border-radius: 18px;
			background: var(--color-surface);
		}

		.kpi {
			display: flex;
			flex: 1 1 0;
			flex-direction: column;
			gap: 8px;
			padding: 22px 24px;
			border-right: 1px solid #2a2f31;
		}

		.kpi-label {
			color: var(--color-muted);
			font-size: 13px;
		}

		.kpi-main {
			color: var(--color-text);
			font-size: 30px;
			font-weight: var(--font-weight-bold);
			letter-spacing: -0.02em;
			line-height: 36px;
		}

		.kpi-value {
			color: var(--color-text);
			font-size: 22px;
			font-weight: var(--font-weight-semibold);
			line-height: 28px;
		}

		.kpi-value.warn {
			color: var(--color-warning);
		}

		.kpi-switch {
			display: flex;
			align-items: center;
			padding: 0 24px;
		}

		.lower {
			flex-direction: row;
			align-items: flex-start;
		}

		.pockets {
			flex: 1;
		}

		.recent {
			flex-shrink: 0;
			width: 420px;
		}
	}
</style>
