<!--
	My withdrawals (W-09), Paper "App — Screens v2" W01/W02 as amended by
	"Withdrawal follow-through v14" WF02 (phone) / WF03 (desktop). The hero
	shows what is reserved for open requests in this network; All / Open /
	Completed / Closed filter the list. Blueprint 44 D5: every row opens the
	withdrawal (WF01 page on phones, the WF04 side panel beside the list on
	desktop, ?w=<id>); cancelling lives in the detail.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { goto } from '$app/navigation';
	import { page as route } from '$app/state';
	import { MediaQuery } from 'svelte/reactivity';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Upload from '@lucide/svelte/icons/upload';
	import {
		WithdrawalAppRoutes,
		WithdrawalPage,
		type Withdrawal as WithdrawalType
	} from '#lib/contract/withdrawals.js';
	import { getJson } from '#lib/client/api.js';
	import { cachedPage, MorePages, type PageLoaded } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { formatMoney, hiddenMoney } from '#lib/money.js';
	import { debited, memberLine, memberStage, phoneLine, withdrawalHref } from '#lib/withdrawals.js';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import Pill from '#lib/ui/money/Pill.svelte';
	import WithdrawalDetail from '#lib/ui/money/WithdrawalDetail.svelte';
	import '#lib/ui/money/money.css';
	import NoAccess from '#lib/ui/app/NoAccess.svelte';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';

	const shell = getContext<Shell>('shell');
	type Filter = 'all' | 'open' | 'completed' | 'closed';

	let filter = $state<Filter>('all');
	let notice = $state<string | null>(null);

	const wide = new MediaQuery('(min-width: 1280px)');
	/** Desktop: the withdrawal open in the side panel (WF04). */
	const selected = $derived(route.url.searchParams.get('w'));
	// A phone opened the desktop link: show the full page instead.
	$effect(() => {
		if (!wide.current && selected) void goto(withdrawalHref(selected), { replaceState: true });
	});

	const DENIED = 'Withdrawals aren’t open to you in this network.';
	const queryFor = (status: Filter, cursor?: string) => {
		// Built and read once per call; not reactive state.
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const params = new URLSearchParams();
		if (status !== 'all') params.set('status', status);
		if (cursor) params.set('cursor', cursor);
		return params.size ? `?${params}` : '';
	};
	async function read(path: string): Promise<PageLoaded<WithdrawalPage>> {
		const exit = await Effect.runPromiseExit(getJson(path, WithdrawalPage));
		if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		const isBackend = failure?._tag === 'BackendError';
		const denied = isBackend && failure.code === 'authorization_denied';
		return {
			ok: false,
			text: denied ? DENIED : 'We couldn’t load your withdrawals.',
			status: isBackend ? failure.status : null
		};
	}

	// Blueprint 23: each filter's first page opens from cache, then refreshes
	// (a new filter is a new `part`, so it reads again by itself). Receipt
	// revisions (receipt facts, evidence ids) are detail-only: never kept.
	const view = cachedPage(shell, {
		kind: 'withdrawals',
		part: () => filter,
		load: () => read(`${WithdrawalAppRoutes.mine}${queryFor(filter)}`),
		keep: (value) => ({
			...value,
			items: value.items.map((w) =>
				w.payout ? { ...w, payout: { ...w.payout, revisions: null } } : w
			)
		})
	});
	const pages = new MorePages<WithdrawalType>(() => view.data);
	const page = $derived(view.data);
	const items = $derived(pages.items);
	const denied = $derived(view.error === DENIED);
	const loadError = $derived(view.data ? null : view.error);
	const loadMore = () => {
		const status = filter;
		return pages.more((cursor) => read(`${WithdrawalAppRoutes.mine}${queryFor(status, cursor)}`));
	};

	const counts = $derived(page?.counts ?? null);
	const filters = $derived<{ key: Filter; label: string }[]>([
		{ key: 'all', label: counts ? `All · ${counts.all}` : 'All' },
		{ key: 'open', label: counts?.open ? `Open · ${counts.open}` : 'Open' },
		{ key: 'completed', label: 'Completed' },
		{ key: 'closed', label: 'Closed' }
	]);

	const panelOpen = $derived(wide.current && !!selected);
	const rowHref = (w: WithdrawalType) =>
		wide.current
			? `/app/withdrawals?w=${encodeURIComponent(w.withdrawalId)}`
			: withdrawalHref(w.withdrawalId);
	function closePanel() {
		void goto('/app/withdrawals', { replaceState: true });
	}
	function changed(w: WithdrawalType) {
		notice = `Cancelled. ${formatMoney(w.amount, 'NGN')} is back in ${w.pocket.name}.`;
		void view.reload();
	}

	const money = (amount: string) =>
		shell.hideAmounts ? hiddenMoney('NGN') : formatMoney(amount, 'NGN');
	const amountText = (w: WithdrawalType) =>
		w.status === 'completed'
			? shell.hideAmounts
				? hiddenMoney('NGN')
				: formatMoney(`-${debited(w)}`, 'NGN')
			: money(w.amount);
	const closed = (w: WithdrawalType) => w.status === 'cancelled' || w.status === 'rejected';
</script>

<svelte:head><title>Withdrawals · Elivate Wallet</title></svelte:head>

{#if denied}
	<NoAccess lead={loadError ?? undefined} />
{:else}
	<div class="mm-page">
		<!-- Blueprint 41: a shorter banner on phones (owner 2026-10-15). -->
		<RootHero
			pose="withdrawals"
			short
			kicker="Reserved for open withdrawals"
			title={page ? formatMoney(page.reserved, 'NGN') : '—'}
		>
			{#if counts && (counts.requested || counts.approved)}
				<div class="hero-chips">
					{#if counts.requested}<span>{counts.requested} requested</span>{/if}
					{#if counts.approved}<span>{counts.approved} approved</span>{/if}
				</div>
			{/if}
		</RootHero>

		<div class="toolbar">
			<div class="segments" role="tablist" aria-label="Show">
				{#each filters as f (f.key)}
					<button
						type="button"
						role="tab"
						aria-selected={filter === f.key}
						onclick={() => (filter = f.key)}>{f.label}</button
					>
				{/each}
			</div>
			{#if shell.canAct}
				<a class="mm-btn primary new" href="/app/withdrawals/new">
					<Upload size={18} strokeWidth={1.8} /> New withdrawal
				</a>
			{/if}
		</div>

		<CacheNote savedAt={view.savedAt} online={shell.online} failed={view.error !== null} />

		{#if notice}<p class="mm-notice" role="status">{notice}</p>{/if}

		<div class="mm-split wd-split" class:open={panelOpen}>
			<div class="mm-col">
				{#if !page && !loadError}
					<div class="mm-skeleton" aria-hidden="true"></div>
				{:else if loadError}
					<p class="mm-empty" role="alert">{loadError}</p>
				{:else if items.length === 0}
					<p class="mm-empty">
						{filter === 'all' ? 'No withdrawals yet.' : 'Nothing here.'}
					</p>
				{:else}
					<div class="wd-list">
						<div class="wd-head" aria-hidden="true">
							<span class="c-tile"></span>
							<span class="c-main">Withdrawal</span>
							<span class="c-from">From</span>
							<span class="c-status">Status</span>
							<span class="c-amount">Amount</span>
							<span class="c-go"></span>
						</div>
						<ul class="wd-rows">
							{#each items as w (w.withdrawalId)}
								{@const stage = memberStage(w)}
								<li>
									<a
										class="wd-row"
										href={rowHref(w)}
										aria-current={panelOpen && selected === w.withdrawalId ? 'true' : undefined}
										data-sveltekit-noscroll={wide.current ? '' : undefined}
										data-sveltekit-replacestate={panelOpen ? '' : undefined}
									>
										<span class="c-tile tile" aria-hidden="true" data-pending-slot
											><ArrowUp size={16} strokeWidth={1.6} /></span
										>
										<span class="c-main names">
											<span class="dest"
												><span class="bank">{w.destination.bankName ?? 'Bank'}</span><span
													class="last4">&nbsp;•• {w.destination.accountLast4}</span
												></span
											>
											<span class="sub phone">{phoneLine(w)}</span>
											<span class="sub desk">{memberLine(w, undefined, panelOpen)}</span>
										</span>
										<span class="c-from from">{w.pocket.name}</span>
										<span class="c-status status"><Pill {...stage} /></span>
										<span class="c-amount figures">
											<span class="amount" class:muted={closed(w)}>{amountText(w)}</span>
											<span class="phone-pill"><Pill {...stage} /></span>
										</span>
										<span class="c-go go" aria-hidden="true"
											><ChevronRight size={18} strokeWidth={2} /></span
										>
									</a>
								</li>
							{/each}
						</ul>
					</div>
					{#if pages.nextCursor}
						<button type="button" class="mm-btn more" disabled={pages.loading} onclick={loadMore}
							>{pages.loading ? 'Loading…' : 'Show more'}</button
						>
						{#if pages.error}<p class="mm-empty" role="alert">{pages.error}</p>{/if}
					{/if}
				{/if}
			</div>
			{#if panelOpen && selected}
				{#key selected}
					<WithdrawalDetail
						id={selected}
						variant="panel"
						onClose={closePanel}
						onChanged={changed}
					/>
				{/key}
			{/if}
		</div>
	</div>
{/if}

<style>
	.hero-chips {
		display: flex;
		flex-wrap: wrap;
		gap: 8px 10px;
		margin-top: 8px;
	}

	.hero-chips span {
		padding: 5px 12px;
		border: 1px solid #ffffff2e;
		border-radius: var(--radius-pill);
		color: #f2f4f4;
		font-size: 13px;
		line-height: 18px;
	}

	.toolbar {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
	}

	.segments {
		display: flex;
		gap: 2px;
		padding: 4px;
		overflow-x: auto;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: var(--color-surface);
	}

	.segments button {
		flex-shrink: 0;
		height: 36px;
		padding: 0 16px;
		border: 0;
		border-radius: var(--radius-pill);
		background: none;
		color: var(--color-muted);
		font: inherit;
		font-size: var(--text-14);
		cursor: pointer;
	}

	.segments button[aria-selected='true'] {
		background: var(--color-raised);
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.new {
		flex: 0 0 auto;
	}

	.more {
		align-self: center;
		flex: 0 0 auto;
	}

	/* ── List (Paper WF02 phone, WF03 desktop; Blueprint 44 D5) ── */
	.wd-list {
		display: flex;
		flex-direction: column;
		padding: 0 16px;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 20px;
		background: var(--color-surface);
	}

	.wd-head {
		display: none;
	}

	.wd-rows {
		display: flex;
		flex-direction: column;
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.wd-rows li + li {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
	}

	.wd-row {
		display: flex;
		align-items: center;
		gap: 12px;
		margin-inline: -8px;
		padding: 14px 8px;
		border-radius: 14px;
		color: inherit;
		text-decoration: none;
		-webkit-tap-highlight-color: transparent;
	}

	/* The press answers at once (Blueprint 41). */
	.wd-row:active {
		background: color-mix(in oklab, var(--color-text) 6%, transparent);
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
		color: color-mix(in oklab, var(--color-text) 88%, transparent);
	}

	.names {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 3px;
		min-width: 0;
	}

	/* "<Bank> •• last4": the bank name gives way, the last four never do. */
	.dest {
		display: flex;
		min-width: 0;
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		white-space: nowrap;
	}

	.bank {
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.last4 {
		flex-shrink: 0;
	}

	.sub {
		overflow: hidden;
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: 16px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.sub.desk,
	.from,
	.status,
	.go {
		display: none;
	}

	.figures {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		flex-shrink: 0;
		gap: 4px;
	}

	.amount {
		color: var(--color-text);
		font-size: var(--text-14);
		font-variant-numeric: tabular-nums;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		white-space: nowrap;
	}

	/* Closed: never moved. Muted, kept at AA contrast. */
	.amount.muted {
		color: var(--color-muted);
		font-weight: var(--font-weight-regular);
	}

	.phone-pill :global(.mm-pill) {
		padding: 2px 8px;
		font-size: 11px;
		font-weight: var(--font-weight-medium);
		line-height: 14px;
	}

	@media (min-width: 1024px) {
		.wd-split.open {
			gap: 24px;
		}

		.wd-list {
			padding: 0 24px 4px;
		}

		.wd-head {
			display: flex;
			align-items: center;
			gap: 16px;
			height: 44px;
			border-bottom: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
			color: var(--color-muted);
			font-family: var(--font-mono);
			font-size: 11px;
			font-weight: var(--font-weight-medium);
			letter-spacing: 0.06em;
			line-height: 14px;
			text-transform: uppercase;
		}

		.wd-rows li + li {
			border-top: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		}

		.wd-row {
			gap: 16px;
			height: 72px;
			margin-inline: -12px;
			padding: 0 12px;
		}

		@media (hover: hover) {
			.wd-row:hover {
				background: color-mix(in oklab, var(--color-text) 3%, transparent);
			}
		}

		/* Selected (panel open): a lighter fill and a quiet outline, never an edge bar. */
		.wd-row[aria-current='true'] {
			background: color-mix(in oklab, var(--color-text) 4%, var(--color-surface));
			outline: 1px solid color-mix(in oklab, var(--color-text) 12%, transparent);
			outline-offset: -1px;
		}

		.c-tile {
			width: 36px;
			flex-shrink: 0;
		}

		.c-main {
			flex: 1;
			min-width: 0;
		}

		.c-from {
			display: block;
			width: 180px;
			flex-shrink: 0;
		}

		.c-status {
			display: flex;
			width: 110px;
			flex-shrink: 0;
		}

		.c-amount {
			width: 130px;
			flex-shrink: 0;
			text-align: right;
			justify-content: flex-end;
		}

		.c-go {
			display: flex;
			justify-content: flex-end;
			width: 28px;
			flex-shrink: 0;
		}

		/* With the panel open there is no room for the pocket (WF04). */
		.wd-split.open .c-from {
			display: none;
		}

		.from {
			overflow: hidden;
			color: var(--color-text);
			font-size: var(--text-14);
			line-height: 18px;
			text-overflow: ellipsis;
			white-space: nowrap;
		}

		.go {
			color: color-mix(in oklab, var(--color-muted) 55%, var(--color-canvas));
		}

		.sub.phone,
		.phone-pill {
			display: none;
		}

		.sub.desk {
			display: block;
		}

		.amount {
			font-size: 15px;
		}
	}

	:global([data-theme='light']) .wd-list {
		border-color: var(--color-border);
	}
</style>
