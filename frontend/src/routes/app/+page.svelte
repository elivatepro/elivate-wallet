<!--
	Home, Paper "App — Screens v3" H04 (desktop) / T04-style mobile, H06 hidden
	amounts, H09 no income yet. Own money in the selected network only, one
	currency at a time (W-07: no cross-currency total). Loaded from /api/home;
	the last good view is kept on this device for offline reading (36a), and
	labelled by the shell's offline banner.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ArrowDown from '@lucide/svelte/icons/arrow-down';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import Landmark from '@lucide/svelte/icons/landmark';
	import PieChart from '@lucide/svelte/icons/chart-pie';
	import type { HomeView } from '#lib/contract/app.js';
	import type { Currency } from '#lib/contract/ledger.js';
	import { loadHome } from '#lib/client/api.js';
	import { browserStore, lastScope, readCache, writeCache } from '#lib/client/device-cache.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { formatMoney, hiddenMoney, isZero } from '#lib/money.js';
	import BalanceCard from '#lib/ui/app/BalanceCard.svelte';
	import CurrencySwitch from '#lib/ui/app/CurrencySwitch.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';

	const shell = getContext<Shell>('shell');

	let home = $state<HomeView | null>(null);
	let failed = $state<string | null>(null);
	let chosen = $state<Currency | null>(null);

	const DOTS = [
		'var(--color-accent)',
		'var(--color-success)',
		'var(--color-info)',
		'var(--color-warning)',
		'#c9a3ff',
		'var(--color-muted)'
	];

	const scope = $derived(
		shell.state.kind === 'ready'
			? { uid: shell.state.view.state.uid, workspaceId: shell.state.view.workspace.membershipId }
			: null
	);

	$effect(() => {
		const kind = shell.state.kind;
		if (kind === 'ready' && scope) {
			const current = scope;
			const controller = new AbortController();
			void Effect.runPromiseExit(loadHome(fetch, controller.signal)).then((exit) => {
				if (controller.signal.aborted) return;
				if (Exit.isSuccess(exit)) {
					home = exit.value;
					failed = null;
					const store = browserStore();
					if (store) writeCache(store, current, 'balances', exit.value);
					return;
				}
				const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
				if (failure?._tag === 'TransportError' && failure.reason === 'aborted') return;
				failed =
					failure?._tag === 'BackendError' ? failure.message : 'We couldn’t load your wallet.';
			});
			return () => controller.abort();
		}
		if (kind === 'offline' && !home) {
			const store = browserStore();
			const last = store ? lastScope(store) : null;
			home = (store && last && readCache<HomeView>(store, last, 'balances')?.data) || null;
		}
	});

	const network = $derived(home?.network ?? null);
	const currencies = $derived<Currency[]>(network ? network.currencies.map((c) => c.currency) : []);
	const currency = $derived<Currency | null>(
		chosen && currencies.includes(chosen) ? chosen : (currencies[0] ?? null)
	);
	const balance = $derived(network?.currencies.find((c) => c.currency === currency) ?? null);
	const percentOf = (pocketId: string) =>
		home?.split?.find((s) => s.pocketId === pocketId)?.percent ?? null;
	const pockets = $derived(
		network
			? network.pockets
					.map((p, i) => ({
						...p,
						dot: DOTS[i % DOTS.length],
						available: balance?.pockets?.find((b) => b.pocketId === p.pocketId)?.available ?? '0'
					}))
					.filter((p) => p.kind === 'ordinary' || !isZero(p.available))
			: []
	);
	const activity = $derived(home?.activity.filter((a) => a.currency === currency) ?? []);
	const firstName = $derived(
		shell.state.kind === 'ready' ? (shell.state.view.profile?.name?.split(' ')[0] ?? null) : null
	);
	const greeting = $derived.by(() => {
		const hour = new Date().getHours();
		const part = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
		return firstName ? `${part}, ${firstName}` : part;
	});
	const money = (amount: string, signed = false) =>
		currency
			? shell.hideAmounts
				? hiddenMoney(currency)
				: formatMoney(amount, currency, signed)
			: '';
	const day = (iso: string) =>
		new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short' }).format(new Date(iso));
	const canSplit = $derived(
		shell.state.kind === 'ready' &&
			(shell.state.view.capabilities?.permissions ?? []).includes('manage_allocation')
	);
	const setCurrency = (c: Currency) => (chosen = c);
</script>

<svelte:head><title>Home · Elivate Wallet</title></svelte:head>

{#if !home && !failed && shell.state.kind !== 'offline'}
	<div class="skeleton" aria-hidden="true"></div>
	<p class="visually-hidden" role="status">Loading your wallet</p>
{:else if failed && !home}
	<RootHero pose="load-error" title="Couldn’t load your wallet" lead={failed} compact />
{:else if !network || !balance || !currency}
	<RootHero
		pose="home-empty"
		title="No money in yet"
		lead="Your pockets fill up when income is recorded."
		compact
	/>
	{#if canSplit}
		<nav class="actions" aria-label="Wallet actions">
			<a class="action" href="/app/split"
				><PieChart size={18} strokeWidth={1.6} aria-hidden="true" />Pockets &amp; split</a
			>
		</nav>
	{/if}
{:else}
	<header class="head">
		<h1 tabindex="-1">{greeting}</h1>
		{#if currencies.length > 1}
			<div class="switch-desktop">
				<CurrencySwitch {currencies} bind:currency={() => currency!, setCurrency} size="md" />
			</div>
		{/if}
	</header>

	<BalanceCard
		{balance}
		{currencies}
		bind:currency={() => currency, setCurrency}
		hidden={shell.hideAmounts}
		onToggleHidden={() => shell.setHideAmounts(!shell.hideAmounts)}
	/>

	<nav class="actions" aria-label="Wallet actions">
		<a class="action" href="/app/payout-accounts"
			><Landmark size={18} strokeWidth={1.6} aria-hidden="true" />Payout accounts</a
		>
		{#if canSplit}
			<a class="action" href="/app/split"
				><PieChart size={18} strokeWidth={1.6} aria-hidden="true" />Pockets &amp; split</a
			>
		{/if}
	</nav>

	<div class="grid">
		<section aria-labelledby="pockets-label">
			<h2 class="section-label" id="pockets-label">Pockets</h2>
			<ul class="pockets">
				{#each pockets as p (p.pocketId)}
					<li class="pocket">
						<span class="dot-tile" aria-hidden="true"
							><span class="dot" style:background={p.dot}></span></span
						>
						<span class="pocket-text">
							<span class="pocket-name">{p.name}</span>
							{#if percentOf(p.pocketId)}<span class="pocket-sub"
									>{percentOf(p.pocketId)}% of income</span
								>{/if}
						</span>
						<span class="pocket-amount">{money(p.available)}</span>
					</li>
				{/each}
			</ul>
		</section>

		<section aria-labelledby="activity-label">
			<h2 class="section-label" id="activity-label">Recent activity</h2>
			{#if activity.length === 0}
				<p class="empty">No activity in {currency} yet.</p>
			{:else}
				<ul class="activity">
					{#each activity as item (item.transactionId + item.currency)}
						{@const credit = !item.amount.startsWith('-')}
						<li class="tx">
							<span class="tx-icon" class:credit aria-hidden="true">
								{#if credit}<ArrowDown size={16} strokeWidth={1.8} />{:else}<ArrowUp
										size={16}
										strokeWidth={1.8}
									/>{/if}
							</span>
							<span class="tx-text">
								<span class="tx-title">{item.type === 'income' ? 'Income' : item.type}</span>
								<span class="tx-sub">{day(item.postedAt)} · {item.reference}</span>
							</span>
							<span class="tx-status">Posted</span>
							<span class="tx-amount" class:credit>{money(item.amount, true)}</span>
						</li>
					{/each}
				</ul>
			{/if}
		</section>
	</div>
{/if}

<style>
	.skeleton {
		height: 300px;
		border-radius: 22px;
		background: var(--color-surface);
	}

	.head {
		display: none;
	}

	h1 {
		color: var(--color-text);
		font-size: 32px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 40px;
		outline: none;
	}

	.actions {
		display: flex;
		flex-wrap: wrap;
		gap: 10px;
		margin-top: 20px;
	}

	.action {
		display: inline-flex;
		align-items: center;
		gap: 10px;
		min-height: 48px;
		padding: 0 20px;
		border-radius: var(--radius-pill);
		border: 1px solid color-mix(in oklab, var(--color-text) 18%, transparent);
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		text-decoration: none;
	}

	.grid {
		display: flex;
		flex-direction: column;
		gap: 28px;
		margin-top: 28px;
	}

	.section-label {
		margin-bottom: 12px;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.14em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.pockets,
	.activity {
		margin: 0;
		padding: 0;
		list-style: none;
		border-radius: var(--radius-16);
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		background: var(--color-surface);
	}

	.pocket,
	.tx {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 14px 18px;
	}

	.pocket + .pocket,
	.tx + .tx {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.dot-tile {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		border-radius: var(--radius-8);
		background: color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.dot {
		width: 10px;
		height: 10px;
		border-radius: var(--radius-pill);
	}

	.pocket-text,
	.tx-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		min-width: 0;
	}

	.pocket-name,
	.tx-title {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 20px;
	}

	.pocket-sub,
	.tx-sub {
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
		overflow-wrap: anywhere;
	}

	.pocket-amount,
	.tx-amount {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		font-variant-numeric: tabular-nums;
		text-align: right;
	}

	.tx-icon {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--color-text) 8%, transparent);
		color: var(--color-text);
	}

	.tx-icon.credit {
		background: color-mix(in oklab, var(--color-success) 14%, transparent);
		color: var(--color-success);
	}

	.tx-status {
		display: none;
		color: var(--color-success);
		font-size: 13px;
	}

	.tx-amount.credit {
		color: var(--color-success);
	}

	.empty {
		padding: 18px;
		border-radius: var(--radius-16);
		border: 1px dashed color-mix(in oklab, var(--color-text) 12%, transparent);
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	@media (min-width: 1024px) {
		.skeleton {
			height: 280px;
			border-radius: var(--radius-24);
		}

		.head {
			display: flex;
			align-items: center;
			justify-content: space-between;
			margin-bottom: 28px;
		}

		.grid {
			display: grid;
			grid-template-columns: minmax(0, 400px) minmax(0, 1fr);
			gap: 24px;
		}

		.tx-status {
			display: block;
			width: 90px;
		}
	}
</style>
