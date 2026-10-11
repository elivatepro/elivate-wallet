<!--
	Blueprint 25: the network overview (Paper "Navigation v5" NV01 mobile, NV03
	desktop). Home of a leadership workspace that holds no money (President
	Team, a director whose funds are not managed) and the Team overview page of
	every other leader (W-07 Leadership).

	Two reads, each shown from its saved copy first (Blueprint 23):
	- /api/overview (api.leadership_overview): income recorded this month and
	  last, the weekly bars, members and invitations out;
	- /api/overview/offices (api.leadership_offices): "Offices this month".
	Both count only the scope this workspace may see and say what they leave
	out. One currency at a time; amounts are never added across currencies.
	"Needs your action" counts the bell's live tasks (Blueprint 13).
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import ArrowRight from '@lucide/svelte/icons/arrow-right';
	import ArrowRightLeft from '@lucide/svelte/icons/arrow-right-left';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import File from '@lucide/svelte/icons/file';
	import Plus from '@lucide/svelte/icons/plus';
	import UserRound from '@lucide/svelte/icons/user-round';
	import Wallet from '@lucide/svelte/icons/wallet';
	import { LeadershipOffices, LeadershipOverview, type Currency } from '#lib/contract/ledger.js';
	import type { Bell } from '#lib/client/bell.svelte.js';
	import { loadView } from '#lib/client/org.svelte.js';
	import { cachedPage } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { monthLabel } from '#lib/activity.js';
	import { formatMoney, hiddenMoney, isZero } from '#lib/money.js';
	import type { NavModel } from '#lib/nav.js';
	import CacheNote from './CacheNote.svelte';
	import NoAccess from './NoAccess.svelte';
	import RootHero from './RootHero.svelte';

	let {
		greeting = true,
		heldFigures = false
	}: {
		/** Home greets the person; the Team page names the scope instead. */
		greeting?: boolean;
		/** The Team page also shows what is reserved and available. */
		heldFigures?: boolean;
	} = $props();

	const shell = getContext<Shell>('shell');
	const bell = getContext<Bell>('bell');
	const navOf = getContext<() => NavModel>('nav');
	const nav = $derived(navOf());

	/**
	 * The network's month: its configured time zone (the backend allows
	 * Africa/Lagos only today). The offices read names it; the overview follows.
	 */
	let zone = $state('Africa/Lagos');
	const overview = cachedPage(shell, {
		kind: 'wallets',
		part: () => 'overview',
		load: () => loadView(`/api/overview?${new URLSearchParams({ tz: zone })}`, LeadershipOverview)
	});
	const offices = cachedPage(shell, {
		kind: 'wallets',
		part: () => 'offices',
		load: () => loadView('/api/overview/offices', LeadershipOffices)
	});
	$effect(() => {
		const named = offices.fresh ? offices.data?.period.timeZone : undefined;
		if (named && named !== zone) {
			zone = named;
			void overview.reload();
		}
	});

	const view = $derived(overview.data);
	const rows = $derived(offices.data);
	const denied = $derived(overview.errorStatus === 403);

	const permitted = (key: string) =>
		shell.state.kind === 'ready' &&
		(shell.state.view.capabilities?.permissions ?? []).includes(key);

	// ── Currency (one at a time) ──
	let chosen = $state<Currency | null>(null);
	const currencies = $derived<Currency[]>(view?.currencies.map((c) => c.currency) ?? []);
	const currency = $derived<Currency | null>(
		chosen && currencies.includes(chosen) ? chosen : (currencies[0] ?? null)
	);
	const figures = $derived(view?.currencies.find((c) => c.currency === currency) ?? null);
	const money = (amount: string) =>
		currency ? (shell.hideAmounts ? hiddenMoney(currency) : formatMoney(amount, currency)) : '';

	const month = $derived(view ? monthLabel(view.period.month) : '');
	const previousMonth = $derived(view ? monthLabel(view.period.previousMonth) : '');
	/** "↑ 12% on September · ₦13,231,000.00": a display ratio; amounts stay exact strings. */
	const change = $derived.by(() => {
		if (!figures || isZero(figures.incomePreviousMonth)) return null;
		const now = Number(figures.incomeThisMonth);
		const before = Number(figures.incomePreviousMonth);
		const pct = Math.round(((now - before) / before) * 100);
		return {
			up: pct >= 0,
			text: `${pct >= 0 ? '↑' : '↓'} ${Math.abs(pct)}% on ${previousMonth} · ${money(figures.incomePreviousMonth)}`
		};
	});

	/** Weekly bars (presentation only): the best week in the accent, this week lighter. */
	const bars = $derived.by(() => {
		if (!figures) return [];
		const values = figures.weeks.map((w) => Number(w.income));
		const max = Math.max(...values, 0);
		const best = max > 0 ? values.indexOf(max) : -1;
		return figures.weeks.map((w, i) => ({
			start: w.start,
			income: w.income,
			height: max > 0 ? Math.max(8, Math.round((Number(w.income) / max) * 72)) : 8,
			best: i === best,
			current: i === figures.weeks.length - 1,
			label:
				i === figures.weeks.length - 1
					? 'This week'
					: `Week of ${new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', timeZone: 'UTC' }).format(new Date(`${w.start}T12:00:00Z`))}`
		}));
	});

	const firstName = $derived(
		shell.state.kind === 'ready' ? (shell.state.view.profile?.name?.split(' ')[0] ?? null) : null
	);
	const hello = $derived.by(() => {
		const hour = new Date().getHours();
		const part = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
		return firstName ? `${part}, ${firstName}` : part;
	});
	const scopeLine = $derived(
		view ? (view.scope.kind === 'network' ? 'whole network' : view.scope.name) : ''
	);

	// ── Stats ──
	const activeOffices = $derived(
		rows ? rows.offices.filter((o) => o.status === 'active').length : null
	);
	const invites = $derived(view?.members.pendingInvitations ?? null);

	// ── Needs your action (the bell's live tasks) ──
	const tasks = $derived(bell?.tasks ?? null);
	const can = (id: string) => nav.approvals.some((a) => a.id === id);
	const actions = $derived(
		[
			can('queue') && {
				id: 'withdrawals',
				label: 'Withdrawals to approve',
				href: '/app/queue',
				icon: ArrowUp,
				count: tasks?.withdrawals ?? null,
				accent: true
			},
			can('queue') &&
				(tasks?.payouts ?? 0) > 0 && {
					id: 'payouts',
					label: 'Payouts to record',
					href: '/app/queue',
					icon: Wallet,
					count: tasks?.payouts ?? null,
					accent: false
				},
			can('identity') && {
				id: 'identity',
				label: 'Identity reviews',
				href: '/app/reviews',
				icon: UserRound,
				count: tasks?.identity ?? null,
				accent: false
			},
			can('evidence') && {
				id: 'evidence',
				label: 'Evidence to check',
				href: '/app/evidence',
				icon: File,
				count: tasks?.evidence ?? null,
				accent: false
			},
			can('transfers') &&
				(tasks?.transfers ?? 0) > 0 && {
					id: 'transfers',
					label: 'Pocket moves to approve',
					href: '/app/transfers',
					icon: ArrowRightLeft,
					count: tasks?.transfers ?? null,
					accent: false
				}
		].filter((a) => a !== false)
	);

	// ── Offices this month: the chosen currency, most income first ──
	const OFFICE_ROWS = 5;
	const officeRows = $derived.by(() => {
		if (!rows || !currency) return [];
		const amount = (o: (typeof rows.offices)[number]) =>
			o.income.find((i) => i.currency === currency)?.amount ?? '0.00';
		return [...rows.offices]
			.map((o) => ({ ...o, amount: amount(o) }))
			.sort((a, b) => Number(b.amount) - Number(a.amount) || a.name.localeCompare(b.name))
			.slice(0, OFFICE_ROWS);
	});
	const excluded = $derived(Math.max(view?.excluded.members ?? 0, rows?.excluded.members ?? 0));
	const hasOffices = $derived(nav.sections.some((s) => s.items.some((i) => i.id === 'offices')));
	const memberWord = (n: number) => `${n} member${n === 1 ? '' : 's'}`;
</script>

<CacheNote
	savedAt={overview.savedAt}
	online={shell.online}
	failed={overview.error !== null && view !== null}
/>
{#if !view && !overview.error}
	<div class="skeleton" aria-hidden="true"></div>
	<p class="visually-hidden" role="status">Loading the overview</p>
{:else if denied && !view}
	<NoAccess lead="This workspace has no team overview." />
{:else if !view}
	<RootHero
		pose="load-error"
		title="Couldn’t load the overview"
		lead={overview.error ?? ''}
		compact
	/>
{:else}
	<div class="overview">
		<header class="head">
			<div class="titles">
				<p class="eyebrow-line">
					{month} ·
					<span class="narrow"
						>{view.scope.kind === 'network' ? 'network overview' : scopeLine}</span
					><span class="wide">{scopeLine}</span>
				</p>
				<h1 tabindex="-1">{greeting ? hello : view.scope.name}</h1>
			</div>
			<div class="head-actions">
				{#if permitted('view_scoped_financial_reports') || permitted('export_scoped_reports')}
					<a class="pill outline" href="/app/reports">Export report</a>
				{/if}
				{#if permitted('invite_members')}
					<a class="pill solid" href="/app/invitations"
						><Plus size={16} strokeWidth={2} aria-hidden="true" />Invite a member</a
					>
				{/if}
			</div>
		</header>

		<div class="top">
			<section class="hero" aria-labelledby="hero-label">
				<div class="hero-shade" aria-hidden="true"></div>
				<div class="hero-row">
					<h2 class="hero-label" id="hero-label">Income recorded this month</h2>
					{#if currencies.length > 1 && currency}
						<div class="switch" role="group" aria-label="Currency">
							{#each currencies as c (c)}
								<button type="button" aria-pressed={c === currency} onclick={() => (chosen = c)}
									>{c}</button
								>
							{/each}
						</div>
					{/if}
				</div>
				{#if figures}
					<div class="hero-figures">
						<p class="hero-amount" data-testid="network-income">{money(figures.incomeThisMonth)}</p>
						{#if change}
							<p class="hero-change" class:down={!change.up}>{change.text}</p>
						{:else}
							<p class="hero-change quiet">Nothing recorded in {previousMonth}</p>
						{/if}
						{#if heldFigures}
							<p class="hero-change quiet">
								Reserved {money(figures.reserved)} · Available {money(figures.available)}
							</p>
						{/if}
					</div>
					<ol class="bars" aria-label="Income recorded per week, {currency} only">
						{#each bars as bar (bar.start)}
							<li class="bar-slot">
								<span
									class="bar"
									class:best={bar.best}
									class:current={bar.current && !bar.best}
									style:height="{bar.height}px"
									aria-hidden="true"
								></span>
								<span class="visually-hidden">{bar.label}: {money(bar.income)}</span>
							</li>
						{/each}
					</ol>
				{/if}
			</section>

			<div class="side">
				<ul class="stats" aria-label="This network">
					<li class="stat">
						<span class="stat-value">{view.members.active}</span>
						<span class="stat-label">Members</span>
					</li>
					<li class="stat">
						<span class="stat-value">{activeOffices ?? '–'}</span>
						<span class="stat-label">Offices</span>
					</li>
					{#if invites !== null}
						<li class="stat">
							<span class="stat-value">{invites}</span>
							<span class="stat-label">Invites out</span>
						</li>
					{/if}
				</ul>

				{#if actions.length > 0}
					<section class="needs" aria-labelledby="needs-label">
						<h2 class="eyebrow" id="needs-label">Needs your action</h2>
						<ul class="card list">
							{#each actions as action (action.id)}
								{@const Icon = action.icon}
								{@const waiting = (action.count ?? 0) > 0}
								<li>
									<a class="action" href={action.href}>
										<span
											class="action-icon"
											class:accent={action.accent && waiting}
											aria-hidden="true"><Icon size={16} strokeWidth={2} /></span
										>
										<span class="action-label">{action.label}</span>
										{#if action.count !== null}
											<span class="action-count" class:accent={action.accent && waiting}
												>{action.count}<span class="visually-hidden"> waiting</span></span
											>
										{/if}
									</a>
								</li>
							{/each}
						</ul>
					</section>
				{/if}
			</div>
		</div>

		<section class="offices" aria-labelledby="offices-label">
			<div class="offices-head">
				<h2 id="offices-label">Offices this month</h2>
				{#if hasOffices}
					<a class="all" href="/app/offices"
						>All offices <ArrowRight size={14} strokeWidth={2} aria-hidden="true" /></a
					>
				{/if}
			</div>
			{#if !rows && !offices.error}
				<div class="card table-skeleton" aria-hidden="true"></div>
			{:else if !rows}
				<p class="card note" role="alert">{offices.error}</p>
			{:else if officeRows.length === 0}
				<p class="card note">No offices yet.</p>
			{:else}
				<table class="card table">
					<caption class="visually-hidden">
						Members and income recorded this month per office, {currency} only
					</caption>
					<thead>
						<tr>
							<th scope="col">Office</th>
							<th scope="col" class="num-members">Members</th>
							<th scope="col" class="num">Income recorded</th>
						</tr>
					</thead>
					<tbody>
						{#each officeRows as office (office.officeId)}
							<tr>
								<th scope="row">
									<span class="office-name">{office.name}</span>
									<span class="office-sub">{memberWord(office.members)}</span>
								</th>
								<td class="num-members">{office.members}</td>
								<td class="num">{money(office.amount)}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			{/if}
			{#if rows && offices.error !== null}
				<!-- A saved copy whose refresh failed: say how old it is. -->
				<CacheNote savedAt={offices.savedAt} online={shell.online} failed />
			{/if}
			{#if excluded > 0}
				<p class="excluded">
					Figures leave out {memberWord(excluded)} you can’t view.
				</p>
			{/if}
		</section>
	</div>
{/if}

<style>
	.skeleton {
		height: 320px;
		border-radius: 22px;
		background: var(--color-surface);
	}

	.overview {
		display: flex;
		flex-direction: column;
		gap: 18px;
	}

	/* ── Header ── */
	.head {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.titles {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	.eyebrow-line {
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	.eyebrow-line .wide,
	.head-actions {
		display: none;
	}

	h1 {
		color: var(--color-text);
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 34px;
		outline: none;
	}

	.pill {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		height: 44px;
		padding: 0 18px;
		border-radius: var(--radius-pill);
		font-size: var(--text-14);
		line-height: 18px;
		text-decoration: none;
	}

	.pill.outline {
		border: 1px solid var(--color-border);
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.pill.solid {
		background: var(--color-text);
		color: var(--color-canvas);
		font-weight: var(--font-weight-semibold);
	}

	/* ── Hero (the grainy coral card, dark in both themes like T04) ── */
	.top,
	.side {
		display: flex;
		flex-direction: column;
		gap: 18px;
	}

	.hero {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 14px;
		padding: 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 22px;
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 60% 30% / cover;
		background-origin: border-box;
		color: #f2f4f4;
	}

	.hero-shade {
		position: absolute;
		inset: 0;
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(22.8% -0.004 -0.003 / 95%) 0%,
			oklab(22.8% -0.004 -0.003 / 78%) 65%,
			oklab(22.8% -0.004 -0.003 / 35%) 100%
		);
	}

	.hero-row,
	.hero-figures,
	.bars {
		position: relative;
	}

	.hero-row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
	}

	.hero-label {
		color: #d5dadb;
		font-size: 13px;
		font-weight: var(--font-weight-regular);
		line-height: 18px;
	}

	.switch {
		display: flex;
		gap: 4px;
		padding: 3px;
		border-radius: var(--radius-pill);
		background: #0000004d;
	}

	/* 24 px tall (Paper draws 22): the WCAG 2.2 minimum target. */
	.switch button {
		min-width: 44px;
		min-height: 24px;
		padding: 4px 10px;
		border: 0;
		border-radius: var(--radius-pill);
		background: transparent;
		color: #d5dadb;
		font: inherit;
		font-size: var(--text-12);
		line-height: 16px;
		cursor: pointer;
	}

	.switch button[aria-pressed='true'] {
		background: #f2f4f4;
		color: #111314;
		font-weight: var(--font-weight-semibold);
	}

	.switch button:focus-visible {
		outline: 2px solid #ff7f4f;
		outline-offset: 1px;
	}

	.hero-figures {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.hero-amount {
		color: #fff;
		font-size: clamp(26px, 8.6vw, 36px);
		font-weight: var(--font-weight-semibold);
		font-variant-numeric: tabular-nums;
		letter-spacing: -0.02em;
		line-height: 40px;
	}

	.hero-change {
		color: #43c48b;
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.hero-change.down,
	.hero-change.quiet {
		color: #d5dadb;
	}

	.hero-change.quiet {
		font-weight: var(--font-weight-regular);
	}

	/* Paper NV01 shows no bars on phones; NV03 draws them in the card. */
	.bars {
		display: none;
		align-items: flex-end;
		gap: 12px;
		height: 72px;
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.bar-slot {
		display: flex;
		align-items: flex-end;
		height: 100%;
	}

	.bar {
		display: block;
		width: 22px;
		border-radius: var(--radius-pill);
		background: #ffffff26;
	}

	.bar.best {
		background: var(--color-accent);
	}

	.bar.current {
		background: #ffffff14;
	}

	/* ── Stats ── */
	.stats {
		display: flex;
		gap: 10px;
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.stat {
		display: flex;
		flex: 1 1 0;
		flex-direction: column;
		gap: 4px;
		min-width: 0;
		padding: 14px 16px;
		border: 1px solid var(--shell-edge, var(--color-border));
		border-radius: 18px;
		background: var(--color-surface);
	}

	.stat-value {
		color: var(--color-text);
		font-size: 22px;
		font-weight: var(--font-weight-semibold);
		font-variant-numeric: tabular-nums;
		line-height: 28px;
	}

	.stat-label {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	/* ── Needs your action ── */
	.needs {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.eyebrow {
		color: var(--color-accent-text);
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.08em;
		line-height: 14px;
		text-transform: uppercase;
	}

	.card {
		margin: 0;
		overflow: clip;
		border: 1px solid var(--shell-edge, var(--color-border));
		border-radius: 18px;
		background: var(--color-surface);
	}

	.list {
		padding: 0;
		list-style: none;
	}

	.list li + li {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 4%, transparent);
	}

	.action {
		display: flex;
		align-items: center;
		gap: 12px;
		height: 60px;
		padding: 0 16px;
		color: var(--color-text);
		text-decoration: none;
		-webkit-tap-highlight-color: transparent;
	}

	.action:active {
		background: var(--color-raised);
	}

	.action-icon {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 32px;
		height: 32px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--shell-strong, var(--color-text));
	}

	.action-icon.accent {
		background: var(--color-accent-subtle);
		color: var(--color-accent-text);
	}

	.action-label {
		flex: 1;
		min-width: 0;
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 20px;
	}

	.action-count {
		flex-shrink: 0;
		padding: 2px 9px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--color-text);
		font-size: var(--text-12);
		font-weight: var(--font-weight-semibold);
		font-variant-numeric: tabular-nums;
		line-height: 16px;
	}

	.action-count.accent {
		background: var(--color-accent);
		color: var(--button-primary-ink);
	}

	/* ── Offices this month ── */
	.offices {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding-top: 6px;
	}

	.offices-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
	}

	.offices-head h2 {
		color: var(--color-text);
		font-size: var(--text-16);
		font-weight: var(--font-weight-semibold);
		line-height: 24px;
	}

	.all {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		min-height: var(--hit-min);
		color: var(--color-accent-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		text-decoration: none;
	}

	.table {
		width: 100%;
		border-collapse: separate;
		border-spacing: 0;
	}

	.table thead {
		display: none;
	}

	.table th,
	.table td {
		padding: 0 16px;
		text-align: left;
	}

	.table tbody th {
		padding-block: 12px;
	}

	.table tbody tr + tr > * {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 4%, transparent);
	}

	.office-name {
		display: block;
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 20px;
	}

	.office-sub {
		display: block;
		color: var(--color-muted);
		font-size: var(--text-12);
		font-weight: var(--font-weight-regular);
		line-height: var(--leading-16);
	}

	.num-members {
		display: none;
	}

	.num {
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		font-variant-numeric: tabular-nums;
		line-height: 18px;
		text-align: right !important;
		white-space: nowrap;
	}

	.table-skeleton {
		height: 168px;
	}

	.note {
		padding: 18px 20px;
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.excluded {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	/* ── Desktop, Paper NV03 ── */
	@media (min-width: 1024px) {
		.overview {
			gap: 28px;
		}

		.head {
			flex-direction: row;
			align-items: flex-end;
			justify-content: space-between;
		}

		.titles {
			gap: 6px;
		}

		.eyebrow-line {
			font-size: var(--text-14);
		}

		.eyebrow-line .narrow {
			display: none;
		}

		.eyebrow-line .wide {
			display: inline;
		}

		.head-actions {
			display: flex;
			flex-shrink: 0;
			gap: 10px;
		}

		h1 {
			font-size: 40px;
			line-height: 48px;
		}

		.top {
			flex-direction: row;
			align-items: stretch;
			gap: 20px;
		}

		.hero {
			flex: 1.6 1 0;
			gap: 22px;
			padding: 28px;
			border-radius: var(--radius-24);
			background-image: url('/auth-bg/desktop-dark.jpg');
			background-position: 70% 30%;
		}

		.hero-shade {
			background-image: linear-gradient(
				in oklab 90deg,
				oklab(22.8% -0.004 -0.003 / 96%) 0%,
				oklab(22.8% -0.004 -0.003 / 82%) 55%,
				oklab(22.8% -0.004 -0.003 / 30%) 100%
			);
		}

		.hero-label {
			font-size: var(--text-14);
		}

		.switch button {
			padding: 4px 12px;
		}

		.hero-figures {
			gap: 8px;
		}

		.hero-amount {
			font-size: 48px;
			line-height: 52px;
		}

		.hero-change {
			font-size: var(--text-14);
		}

		.bars {
			display: flex;
			margin-top: auto;
		}

		.side {
			flex: 1 1 0;
			gap: 20px;
			min-width: 0;
		}

		.stats {
			gap: 12px;
		}

		.stat {
			padding: 16px 18px;
		}

		.stat-value {
			font-size: 26px;
			line-height: 32px;
		}

		.stat-label {
			font-size: 13px;
			line-height: 18px;
		}

		.offices {
			padding-top: 0;
		}

		.offices-head h2 {
			font-size: 18px;
		}

		.table thead {
			display: table-header-group;
		}

		.table thead th {
			height: 44px;
			padding: 0 20px;
			border-bottom: 1px solid color-mix(in oklab, var(--color-text) 4%, transparent);
			color: var(--shell-faint, var(--color-muted));
			font-size: var(--text-12);
			font-weight: var(--font-weight-regular);
			line-height: 16px;
		}

		.table tbody th,
		.table tbody td {
			height: 56px;
			padding: 0 20px;
		}

		.office-sub {
			display: none;
		}

		.num-members {
			display: table-cell;
			width: 140px;
			color: var(--shell-strong, var(--color-text));
			font-size: var(--text-14);
			line-height: 18px;
		}

		.num {
			width: 200px;
		}

		.table-skeleton {
			height: 212px;
		}
	}
</style>
