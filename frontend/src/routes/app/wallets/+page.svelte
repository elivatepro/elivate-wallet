<!--
	Member wallets (W-07 managed wallets). NOT DRAWN IN PAPER YET: a minimal,
	functional stub waiting on Paper approval (Blueprint 08). Lists members whose
	money the leader may view in this workspace (never their own), per currency;
	?wallet=<id> opens one wallet with its activity, reusing the M03 activity
	composition. The backend authorizes every segment.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import Search from '@lucide/svelte/icons/search';
	import { UUID_PATTERN } from '#lib/contract/common.js';
	import { ManagedWalletPage, type Currency } from '#lib/contract/ledger.js';
	import { getJson } from '#lib/client/api.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { formatMoney, hiddenMoney } from '#lib/money.js';
	import ActivityBrowser from '#lib/ui/app/ActivityBrowser.svelte';

	const shell = getContext<Shell>('shell');

	let query = $state('');
	let applied = $state('');
	let items = $state<ManagedWalletPage['items'][number][]>([]);
	let nextCursor = $state<string | null>(null);
	let loaded = $state(false);
	let failed = $state<string | null>(null);

	const walletParam = $derived(page.url.searchParams.get('wallet'));
	const wallet = $derived(walletParam && UUID_PATTERN.test(walletParam) ? walletParam : null);
	const opened = $derived(items.find((i) => i.walletId === wallet) ?? null);

	$effect(() => {
		const value = query.trim();
		const timer = setTimeout(() => (applied = value), 300);
		return () => clearTimeout(timer);
	});

	async function load(more = false) {
		const p = new SvelteURLSearchParams();
		if (applied) p.set('q', applied);
		if (more && nextCursor) p.set('cursor', nextCursor);
		const exit = await Effect.runPromiseExit(getJson(`/api/wallets?${p}`, ManagedWalletPage));
		if (Exit.isSuccess(exit)) {
			items = more ? [...items, ...exit.value.items] : [...exit.value.items];
			nextCursor = exit.value.nextCursor;
			loaded = true;
			failed = null;
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		failed = failure?._tag === 'BackendError' ? failure.message : 'We couldn’t load the wallets.';
	}

	$effect(() => {
		void applied;
		if (shell.state.kind === 'ready') void load();
	});

	const money = (amount: string, c: Currency) =>
		shell.hideAmounts ? hiddenMoney(c) : formatMoney(amount, c);
</script>

<svelte:head><title>Member wallets · Elivate Wallet</title></svelte:head>

{#if wallet}
	<a class="back" href="/app/wallets"
		><ChevronLeft size={18} strokeWidth={2} aria-hidden="true" />Member wallets</a
	>
	{#if opened}
		<header class="owner">
			<p class="owner-name">{opened.person?.name ?? opened.person?.uid ?? 'Member'}</p>
			{#if opened.person}<p class="owner-uid">{opened.person.uid}</p>{/if}
			<ul class="balances">
				{#each opened.currencies as c (c.currency)}
					<li>
						<span class="b-label">{c.currency} available</span>
						<span class="b-value">{money(c.available, c.currency)}</span>
					</li>
				{/each}
			</ul>
		</header>
	{/if}
	<ActivityBrowser
		{wallet}
		owner={opened?.person?.name ?? null}
		heading={opened?.person?.name ?? 'Activity'}
	/>
{:else}
	<h1 class="title" tabindex="-1">Member wallets</h1>
	<label class="search">
		<Search size={16} strokeWidth={2} aria-hidden="true" />
		<span class="visually-hidden">Search members</span>
		<input type="search" placeholder="Search name or UID" bind:value={query} maxlength="100" />
	</label>
	{#if failed && !loaded}
		<p class="notice" role="alert">{failed}</p>
	{:else if !loaded}
		<p class="notice" role="status">Loading…</p>
	{:else if items.length === 0}
		<p class="notice" role="status">
			{applied ? 'No member matches that search.' : 'No member wallets to show here.'}
		</p>
	{:else}
		<ul class="list">
			{#each items as item (item.walletId)}
				<li>
					<a class="row" href="/app/wallets?wallet={item.walletId}">
						<span class="who">
							<span class="name">{item.person?.name ?? item.person?.uid ?? 'Member'}</span>
							{#if item.person}<span class="uid">{item.person.uid}</span>{/if}
						</span>
						<span class="amounts">
							{#each item.currencies as c (c.currency)}
								<span>{money(c.available, c.currency)}</span>
							{/each}
						</span>
					</a>
				</li>
			{/each}
		</ul>
		{#if nextCursor}<button type="button" class="more" onclick={() => load(true)}>Load more</button
			>{/if}
	{/if}
{/if}

<style>
	.title,
	.owner-name {
		color: var(--color-text);
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 36px;
		outline: none;
	}

	.back {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		min-height: var(--hit-min);
		color: var(--color-muted);
		font-size: var(--text-14);
		text-decoration: none;
	}

	.owner {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	.owner-uid,
	.uid {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
	}

	.balances {
		display: flex;
		flex-wrap: wrap;
		gap: 24px;
		padding-top: 12px;
	}

	.balances li {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	.b-label {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	.b-value {
		color: var(--color-text);
		font-size: var(--text-24);
		font-weight: var(--font-weight-semibold);
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
	}

	.list {
		display: flex;
		flex-direction: column;
		padding: 4px 14px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-16);
		background: var(--color-surface);
	}

	.list li + li {
		border-top: 1px solid var(--color-border);
	}

	.row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		min-height: 64px;
		color: var(--color-text);
		text-decoration: none;
	}

	.who,
	.amounts {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.amounts {
		align-items: flex-end;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
	}

	.name {
		font-size: var(--text-14);
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
</style>
