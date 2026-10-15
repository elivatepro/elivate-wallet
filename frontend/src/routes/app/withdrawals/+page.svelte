<!--
	My withdrawals (W-09), Paper "App — Screens v2" W01 (desktop) / W02 (mobile)
	and the W03/W04 cancel dialog. The hero shows what is reserved for open
	requests in this network; All / Open / Completed / Closed filter the list.
	A requested withdrawal can be cancelled by the member (no PIN, the hold is
	released). An approved one is the approver's to finish or cancel.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import Upload from '@lucide/svelte/icons/upload';
	import {
		Withdrawal,
		WithdrawalAppRoutes,
		WithdrawalPage,
		type Withdrawal as WithdrawalType
	} from '#lib/contract/withdrawals.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import { cachedPage, MorePages, type PageLoaded } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { isUnknownOutcome } from '#lib/recovery.js';
	import { formatMoney } from '#lib/money.js';
	import {
		debited,
		destinationTitle,
		memberLine,
		memberStage,
		moveMessage
	} from '#lib/withdrawals.js';
	import RootDialog from '#lib/ui/account/RootDialog.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import Pill from '#lib/ui/money/Pill.svelte';
	import '#lib/ui/money/money.css';
	import NoAccess from '#lib/ui/app/NoAccess.svelte';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';

	const shell = getContext<Shell>('shell');
	type Filter = 'all' | 'open' | 'completed' | 'closed';

	let filter = $state<Filter>('all');
	let notice = $state<string | null>(null);

	let target = $state<WithdrawalType | null>(null);
	let dialogOpen = $state(false);
	let busy = $state(false);
	let dialogError = $state<string | null>(null);
	let cancelKey = newKey();

	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);

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

	function askCancel(w: WithdrawalType) {
		target = w;
		dialogError = null;
		cancelKey = newKey();
		dialogOpen = true;
	}

	async function confirmCancel() {
		if (!target || !workspaceId) return;
		busy = true;
		dialogError = null;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				WithdrawalAppRoutes.cancelOwn(target.withdrawalId),
				'POST',
				{ idempotencyKey: cancelKey },
				workspaceId,
				Withdrawal
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			dialogOpen = false;
			notice = `Cancelled. ${formatMoney(exit.value.amount, 'NGN')} is back in ${exit.value.pocket.name}.`;
			// The command invalidated 'withdrawals': the list reads again by itself.
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		if (failure && !isUnknownOutcome(failure)) cancelKey = newKey();
		dialogError = moveMessage(failure);
		if (failure?._tag === 'BackendError' && failure.code === 'conflict') void view.reload();
	}

	const amountText = (w: WithdrawalType) =>
		w.status === 'completed' ? formatMoney(`-${debited(w)}`, 'NGN') : formatMoney(w.amount, 'NGN');
	const closed = (w: WithdrawalType) => w.status === 'cancelled' || w.status === 'rejected';
	const when = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(
			new Date(iso)
		);
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

		{#if !page && !loadError}
			<div class="mm-skeleton" aria-hidden="true"></div>
		{:else if loadError}
			<p class="mm-empty" role="alert">{loadError}</p>
		{:else if items.length === 0}
			<p class="mm-empty">
				{filter === 'all' ? 'No withdrawals yet.' : 'Nothing here.'}
			</p>
		{:else}
			<div class="mm-list wd">
				<div class="mm-list-head" aria-hidden="true">
					<span class="lane-icon"></span>
					<span class="wide">Withdrawal</span>
					<span class="from">From</span>
					<span class="st">Status</span>
					<span class="num">Amount</span>
					<span class="lane-action"></span>
				</div>
				{#each items as w (w.withdrawalId)}
					{@const stage = memberStage(w)}
					<div class="mm-row static">
						<span class="lane-icon icon" aria-hidden="true"
							><ArrowUp size={16} strokeWidth={1.8} /></span
						>
						<div class="mm-names wide">
							<span class="mm-name">{destinationTitle(w)}</span>
							<span class="mm-sub">{memberLine(w)}</span>
							<!-- Blueprint 40: what it is for, as written (none before it was asked). -->
							{#if w.reason}<span class="mm-sub for">“{w.reason}”</span>{/if}
							<span class="mobile-only"><Pill {...stage} /></span>
						</div>
						<span class="from mm-muted">{w.pocket.name}</span>
						<span class="mm-status"><Pill {...stage} /></span>
						<span class="mm-amount" class:muted={closed(w)}>{amountText(w)}</span>
						<span class="lane-action">
							{#if w.can.cancel && w.status === 'requested'}
								<button
									type="button"
									class="mm-btn sm"
									disabled={!shell.canAct}
									onclick={() => askCancel(w)}>Cancel</button
								>
							{/if}
						</span>
					</div>
				{/each}
			</div>
			{#if pages.nextCursor}
				<button type="button" class="mm-btn more" disabled={pages.loading} onclick={loadMore}
					>{pages.loading ? 'Loading…' : 'Show more'}</button
				>
				{#if pages.error}<p class="mm-empty" role="alert">{pages.error}</p>{/if}
			{/if}
		{/if}
	</div>
{/if}

{#if target}
	<RootDialog
		bind:open={dialogOpen}
		pose="dialog-remove"
		title="Cancel this withdrawal?"
		summary="The hold is released. No money moves."
		confirmLabel="Cancel withdrawal"
		cancelLabel="Keep it"
		tone="danger"
		{busy}
		error={dialogError}
		onConfirm={confirmCancel}
	>
		{#snippet fields()}
			<div class="cancel-body">
				<p class="mm-muted">Back to {target?.pocket.name}</p>
				<p class="mm-big">{formatMoney(target?.amount ?? '0', 'NGN')}</p>
				<dl class="mm-box facts">
					<div>
						<dt>Was going to</dt>
						<dd>{target ? destinationTitle(target) : ''}</dd>
					</div>
					<div>
						<dt>Requested</dt>
						<dd>{target ? when(target.createdAt) : ''}</dd>
					</div>
					{#if target?.reason}
						<div>
							<dt>For</dt>
							<dd class="for">{target.reason}</dd>
						</div>
					{/if}
					<div>
						<dt>Reference</dt>
						<dd class="mm-ref">{target?.reference}</dd>
					</div>
				</dl>
			</div>
		{/snippet}
	</RootDialog>
{/if}

<style>
	.mm-sub.for {
		color: color-mix(in oklab, var(--color-text) 85%, transparent);
	}

	dd.for {
		overflow-wrap: anywhere;
	}

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

	.wd {
		padding: 0 22px;
	}

	.wd .mm-row {
		padding-inline: 0;
		cursor: default;
	}

	.wd .mm-list-head {
		padding-inline: 0;
	}

	.lane-icon {
		width: 36px;
		flex-shrink: 0;
	}

	.icon {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 36px;
		border-radius: 50%;
		background: var(--color-raised);
		color: var(--color-text);
	}

	.wide {
		flex: 1;
		min-width: 0;
	}

	.from {
		display: none;
		width: 120px;
		flex-shrink: 0;
	}

	.lane-action {
		display: flex;
		justify-content: flex-end;
		width: 88px;
		flex-shrink: 0;
	}

	.mobile-only {
		margin-top: 4px;
	}

	.more {
		align-self: center;
		flex: 0 0 auto;
	}

	.cancel-body {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.facts {
		flex-direction: column;
		align-items: stretch;
		gap: 0;
		margin: 8px 0 0;
		padding: 0 16px;
	}

	.facts div {
		display: flex;
		justify-content: space-between;
		gap: 12px;
		padding: 12px 0;
	}

	.facts div + div {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.facts dt {
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	.facts dd {
		margin: 0;
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
	}

	@media (max-width: 767px) {
		.lane-action:empty,
		.wd .mm-list-head .lane-action {
			display: none;
		}
	}

	@media (min-width: 768px) {
		.from {
			display: block;
		}

		.mobile-only {
			display: none;
		}
	}
</style>
