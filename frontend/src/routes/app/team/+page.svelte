<!--
	Team overview, Paper "App — Screens v1" T01 (desktop) and T04 (mobile hero
	card). One aggregate read for the workspace's scope (W-07 Leadership): only
	authorized members count, excluded scope is said out loud, one currency at
	a time, never a cross-currency total.

	Withdrawal pieces of T01/T04 (Review withdrawals, Payouts completed, Needs
	your action, the payouts bars) arrive with the withdrawals slice; "Export
	report" with statements; "Recently opened" has no decided data source.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Plus from '@lucide/svelte/icons/plus';
	import UserPlus from '@lucide/svelte/icons/user-plus';
	import { LeadershipOverview, type Currency } from '#lib/contract/ledger.js';
	import { getJson } from '#lib/client/api.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { browserTimeZone, monthLabel } from '#lib/activity.js';
	import { formatMoney, hiddenMoney, isZero } from '#lib/money.js';
	import CurrencySwitch from '#lib/ui/app/CurrencySwitch.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';

	const shell = getContext<Shell>('shell');
	const tz = browserTimeZone();

	let overview = $state<LeadershipOverview | null>(null);
	let failed = $state<string | null>(null);
	let chosen = $state<Currency | null>(null);

	$effect(() => {
		if (shell.state.kind !== 'ready') return;
		const controller = new AbortController();
		void Effect.runPromiseExit(
			getJson(`/api/overview?${new URLSearchParams({ tz })}`, LeadershipOverview, controller.signal)
		).then((exit) => {
			if (controller.signal.aborted) return;
			if (Exit.isSuccess(exit)) {
				overview = exit.value;
				failed = null;
				return;
			}
			const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
			if (failure?._tag === 'TransportError' && failure.reason === 'aborted') return;
			failed =
				failure?._tag === 'BackendError' && failure.code === 'authorization_denied'
					? 'This workspace has no team overview.'
					: failure?._tag === 'BackendError'
						? failure.message
						: 'We couldn’t load the overview.';
		});
		return () => controller.abort();
	});

	const can = (permission: string) =>
		shell.state.kind === 'ready' &&
		(shell.state.view.capabilities?.permissions ?? []).includes(permission);

	const currencies = $derived<Currency[]>(overview?.currencies.map((c) => c.currency) ?? []);
	const currency = $derived<Currency | null>(
		chosen && currencies.includes(chosen) ? chosen : (currencies[0] ?? null)
	);
	const setCurrency = (c: Currency) => (chosen = c);
	const figures = $derived(overview?.currencies.find((c) => c.currency === currency) ?? null);
	const month = $derived(overview ? monthLabel(overview.period.month).slice(0, 3) : '');
	const previousMonth = $derived(overview ? monthLabel(overview.period.previousMonth) : '');
	const money = (amount: string) =>
		currency ? (shell.hideAmounts ? hiddenMoney(currency) : formatMoney(amount, currency)) : '';

	/** "↑ 12% vs September". Display ratio only; the amounts themselves stay exact strings. */
	const change = $derived.by(() => {
		if (!figures || isZero(figures.incomePreviousMonth)) return null;
		const now = Number(figures.incomeThisMonth);
		const before = Number(figures.incomePreviousMonth);
		const pct = Math.round(((now - before) / before) * 100);
		return { up: pct >= 0, text: `${pct >= 0 ? '↑' : '↓'} ${Math.abs(pct)}% vs ${previousMonth}` };
	});

	/** Bar heights (presentation only) and a rounded axis. */
	const chart = $derived.by(() => {
		if (!figures || !currency) return null;
		const values = figures.weeks.map((w) => Number(w.income));
		const max = Math.max(...values, 0);
		const step = max > 0 ? niceCeil(max) : 0;
		return {
			axis: step > 0 ? [step, step / 2, 0].map((v) => compact(v, currency)) : [],
			bars: figures.weeks.map((w, i) => ({
				start: w.start,
				label:
					i === figures.weeks.length - 1
						? 'This week'
						: new Intl.DateTimeFormat('en-GB', {
								day: 'numeric',
								month: 'short',
								timeZone: 'UTC'
							}).format(new Date(`${w.start}T12:00:00Z`)),
				height: step > 0 ? Math.round((Number(w.income) / step) * 170) : 0,
				income: w.income,
				current: i === figures.weeks.length - 1
			}))
		};
	});

	function niceCeil(value: number): number {
		const magnitude = 10 ** Math.floor(Math.log10(value));
		for (const m of [1, 2, 2.5, 5, 10]) if (m * magnitude >= value) return m * magnitude;
		return 10 * magnitude;
	}

	function compact(value: number, c: Currency): string {
		const symbol = c === 'NGN' ? '₦' : '$';
		if (value >= 1_000_000) return `${symbol}${+(value / 1_000_000).toFixed(1)}m`;
		if (value >= 1_000) return `${symbol}${+(value / 1_000).toFixed(1)}k`;
		return `${symbol}${value}`;
	}

	const members = $derived(overview?.members ?? null);
	const membersText = $derived(
		members ? `${members.active} active member${members.active === 1 ? '' : 's'}` : ''
	);
	const invitesText = $derived(
		members?.pendingInvitations == null
			? null
			: `${members.pendingInvitations} invite${members.pendingInvitations === 1 ? '' : 's'} pending`
	);
	const excludedText = $derived(
		overview && overview.excluded.members > 0
			? `Totals leave out ${overview.excluded.members} member${overview.excluded.members === 1 ? '' : 's'} you can’t view.`
			: null
	);
</script>

<svelte:head><title>Team overview · Elivate Wallet</title></svelte:head>

{#if !overview && !failed}
	<div class="skeleton" aria-hidden="true"></div>
	<p class="visually-hidden" role="status">Loading the overview</p>
{:else if failed || !overview}
	<RootHero pose="load-error" title="Couldn’t load the overview" lead={failed ?? ''} compact />
{:else}
	<header class="head">
		<h1 tabindex="-1">{overview.scope.name}</h1>
		{#if currencies.length > 1 && currency}
			<CurrencySwitch {currencies} bind:currency={() => currency!, setCurrency} />
		{/if}
	</header>

	<!-- T04 hero card (mobile) -->
	<section class="hero" aria-label="Income recorded this month">
		<div class="hero-shade" aria-hidden="true"></div>
		<RootImage pose="team" class="hero-root" sizes="104px" eager />
		<div class="hero-top">
			<span class="hero-label">Income recorded · {month}</span>
			{#if currencies.length > 1 && currency}
				<CurrencySwitch {currencies} bind:currency={() => currency!, setCurrency} size="sm" />
			{/if}
		</div>
		{#if figures}<p class="hero-amount">{money(figures.incomeThisMonth)}</p>{/if}
		{#if figures}
			<div class="chips">
				<span class="chip warn">Reserved {money(figures.reserved)}</span>
			</div>
		{/if}
	</section>

	{#if can('record_income') || can('invite_members')}
		<nav class="shortcuts" aria-label="Team actions">
			{#if can('record_income')}
				<a class="shortcut coral" href="/app/income">
					<span class="tile coral" aria-hidden="true"><Plus size={20} strokeWidth={2} /></span>
					<span class="sc-text"
						><span class="sc-title">Record income</span><span class="sc-sub"
							>With receipt, split instantly</span
						></span
					>
				</a>
			{/if}
			{#if can('invite_members')}
				<a class="shortcut" href="/app/invitations">
					<span class="tile" aria-hidden="true"><UserPlus size={20} strokeWidth={1.8} /></span>
					<span class="sc-text"
						><span class="sc-title">Invite a member</span><span class="sc-sub"
							>Into {overview.scope.name}</span
						></span
					>
				</a>
			{/if}
		</nav>
	{/if}

	{#if figures}
		<section class="kpis" aria-label="This month">
			<div class="kpi">
				<span class="kpi-label">Income recorded · {month}</span>
				<span class="kpi-value">{money(figures.incomeThisMonth)}</span>
				{#if change}<span class="kpi-sub" class:up={change.up}>{change.text}</span>{/if}
			</div>
			<div class="kpi">
				<span class="kpi-label">Reserved for open requests</span>
				<span class="kpi-value warn">{money(figures.reserved)}</span>
				<span class="kpi-sub">Available {money(figures.available)}</span>
			</div>
			<div class="kpi narrow">
				<span class="kpi-label">Active members</span>
				<span class="kpi-value">{members?.active ?? 0}</span>
				{#if invitesText}<span class="kpi-sub">{invitesText}</span>{/if}
			</div>
		</section>
	{/if}

	{#if chart && currency}
		<section class="card chart" aria-labelledby="chart-title">
			<div class="chart-head">
				<div>
					<h2 id="chart-title">Income recorded</h2>
					<p class="chart-sub">Weekly · {currency} only</p>
				</div>
			</div>
			<div class="plot">
				<div class="axis" aria-hidden="true">
					{#each chart.axis as label, i (i)}<span>{label}</span>{/each}
				</div>
				<ol class="bars">
					{#each chart.bars as bar (bar.start)}
						<li class="bar-slot">
							<span
								class="bar"
								class:current={bar.current}
								style:height="{bar.height}px"
								aria-hidden="true"
							></span>
							<span class="visually-hidden">{bar.label}: {money(bar.income)}</span>
						</li>
					{/each}
				</ol>
			</div>
			<div class="labels" aria-hidden="true">
				{#each chart.bars as bar (bar.start)}<span>{bar.label}</span>{/each}
			</div>
		</section>
	{/if}

	<a class="members" href="/app/wallets">
		<span class="m-text"
			><span class="m-title">{membersText}</span>{#if invitesText}<span class="m-sub"
					>{invitesText}</span
				>{/if}</span
		>
		<ChevronRight size={16} strokeWidth={2} aria-hidden="true" />
	</a>

	{#if excludedText}<p class="excluded">{excludedText}</p>{/if}
{/if}

<style>
	.skeleton {
		height: 300px;
		border-radius: 22px;
		background: var(--color-surface);
	}

	.head,
	.kpis,
	.chart,
	.labels {
		display: none;
	}

	h1 {
		color: var(--color-text);
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 36px;
		outline: none;
	}

	/* ── T04 hero ── */
	.hero {
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

	.hero-shade {
		position: absolute;
		inset: 0;
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(21.5% -0.004 -0.003 / 95%) 0%,
			oklab(21.5% -0.004 -0.003 / 70%) 60%,
			oklab(21.5% -0.004 -0.003 / 20%) 100%
		);
	}

	.hero :global(.hero-root) {
		position: absolute;
		right: -4px;
		bottom: -12px;
		width: 104px;
		height: 140px;
	}

	.hero-top {
		position: relative;
		display: flex;
		align-items: center;
		justify-content: space-between;
	}

	.hero-label {
		color: #d5dadb;
		font-size: 13px;
		line-height: var(--leading-16);
	}

	.hero-amount {
		position: relative;
		color: #fff;
		font-size: 30px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.03em;
		line-height: 36px;
	}

	.chips {
		position: relative;
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 6px;
	}

	.chip {
		padding: 5px 10px;
		border: 1px solid #ffffff1a;
		border-radius: var(--radius-pill);
		background: #1113148c;
		color: #f2f4f4;
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.chip.warn {
		color: #f2b85e;
	}

	/* ── Shortcuts ── */
	.shortcuts {
		display: flex;
		flex-wrap: wrap;
		gap: 10px;
	}

	.shortcut {
		display: flex;
		flex: 1 1 140px;
		flex-direction: column;
		gap: 10px;
		padding: 14px;
		border: 1px solid #ffffff14;
		border-radius: var(--radius-16);
		background: var(--color-surface);
		color: var(--color-text);
		text-decoration: none;
	}

	.shortcut.coral {
		border-color: #ff7f4f40;
		background: var(--color-accent-subtle);
	}

	.tile {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		border-radius: 11px;
		background: var(--color-raised);
		color: var(--color-text);
	}

	.tile.coral {
		background-image: linear-gradient(
			in oklab 135deg,
			oklab(79.8% 0.091 0.081) 0%,
			oklab(73.5% 0.128 0.109) 55%,
			oklab(68.2% 0.137 0.111) 100%
		);
		color: #14100e;
	}

	.sc-text {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.sc-title {
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
	}

	.sc-sub {
		display: none;
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	/* ── Members strip ── */
	.members {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 14px 16px;
		border: 1px solid #ffffff14;
		border-radius: var(--radius-16);
		background: var(--color-surface);
		color: #7d8588;
		text-decoration: none;
	}

	.m-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
	}

	.m-title {
		color: var(--color-text);
		font-size: var(--text-14);
		line-height: 18px;
	}

	.m-sub,
	.excluded {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	:global([data-theme='light']) .shortcut,
	:global([data-theme='light']) .members,
	:global([data-theme='light']) .kpis,
	:global([data-theme='light']) .card {
		border-color: var(--color-border);
	}

	/* ── Desktop (T01) ── */
	@media (min-width: 1024px) {
		.head {
			display: flex;
			align-items: center;
			justify-content: space-between;
			gap: 16px;
		}

		.hero,
		.members {
			display: none;
		}

		.shortcuts {
			flex-wrap: nowrap;
			gap: 12px;
		}

		.shortcut {
			flex: 1 1 0;
			flex-direction: row;
			align-items: center;
			gap: 14px;
			padding: 16px;
		}

		.tile {
			width: 40px;
			height: 40px;
			border-radius: 12px;
		}

		.sc-sub {
			display: block;
		}

		.kpis {
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
		}

		.kpi + .kpi {
			border-left: 1px solid #ffffff0f;
		}

		.kpi.narrow {
			flex-grow: 0.7;
		}

		.kpi-label {
			color: var(--color-muted);
			font-size: 13px;
			line-height: var(--leading-16);
		}

		.kpi-value {
			color: var(--color-text);
			font-size: 28px;
			font-weight: var(--font-weight-semibold);
			letter-spacing: -0.02em;
			line-height: 34px;
		}

		.kpi-value.warn {
			color: var(--color-warning);
		}

		.kpi-sub {
			color: var(--color-muted);
			font-size: var(--text-12);
			line-height: var(--leading-16);
		}

		.kpi-sub.up {
			color: var(--color-success);
		}

		.card {
			display: flex;
			flex-direction: column;
			gap: 20px;
			padding: 24px;
			border: 1px solid #ffffff14;
			border-radius: 18px;
			background: var(--color-surface);
		}

		.chart h2 {
			color: var(--color-text);
			font-size: var(--text-16);
			font-weight: var(--font-weight-semibold);
			line-height: var(--leading-20);
		}

		.chart-sub {
			color: var(--color-muted);
			font-size: var(--text-12);
			line-height: var(--leading-16);
		}

		.plot {
			display: flex;
			gap: 12px;
		}

		.axis {
			display: flex;
			flex-direction: column;
			justify-content: space-between;
			width: 36px;
			height: 206px;
			color: #7d8588;
			font-family: var(--font-mono);
			font-size: 11px;
			line-height: 14px;
		}

		.bars {
			display: flex;
			flex: 1;
			align-items: flex-end;
			justify-content: space-around;
			height: 200px;
			border-bottom: 1px solid var(--color-border);
		}

		.bar-slot {
			display: flex;
			align-items: flex-end;
			height: 170px;
		}

		.bar {
			display: block;
			width: 22px;
			border-radius: 6px 6px 0 0;
			background: var(--color-accent);
		}

		.bar.current {
			opacity: 0.55;
		}

		.labels {
			display: flex;
			justify-content: space-around;
			padding-left: 48px;
			color: var(--color-muted);
			font-size: var(--text-12);
			line-height: var(--leading-16);
		}
	}
</style>
