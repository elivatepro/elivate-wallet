<!--
	Withdrawal queue (W-10), Paper "App — Screens v1" T03 (desktop) / T06
	(mobile) with the C01/C05/C07 panels: Needs action, Verifying, Completed,
	Rejected & cancelled. Lists only members this person may approve for,
	never their own. Approving doesn't move money: the amount stays reserved
	until the payout receipt matches (or a reviewer clears it).
-->
<script lang="ts">
	import { getContext, untrack } from 'svelte';
	import { page as appPage } from '$app/state';
	import { Cause, Effect, Exit, Option } from 'effect';
	import {
		Withdrawal,
		WithdrawalAppRoutes,
		WithdrawalPage,
		type Withdrawal as WithdrawalType
	} from '#lib/contract/withdrawals.js';
	import { getJson } from '#lib/client/api.js';
	import { cachedPage, MorePages, type PageLoaded } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { initials } from '#lib/activity.js';
	import { formatMoney } from '#lib/money.js';
	import {
		checkDelayed,
		currentRevision,
		debited,
		queueLine,
		withdrawalStage
	} from '#lib/withdrawals.js';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import Pill from '#lib/ui/money/Pill.svelte';
	import QueueTabs from '#lib/ui/money/QueueTabs.svelte';
	import WithdrawalPanel from '#lib/ui/money/WithdrawalPanel.svelte';
	import '#lib/ui/money/money.css';
	import NoAccess from '#lib/ui/app/NoAccess.svelte';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';

	const shell = getContext<Shell>('shell');
	/** Navigation hint only; the backend authorizes every command. */
	const can = (permission: string) =>
		shell.state.kind === 'ready' &&
		(shell.state.view.capabilities?.permissions ?? []).includes(permission);
	type Tab = 'action' | 'verifying' | 'completed' | 'closed';

	// Deep link (W09 "View withdrawal"): ?tab=completed&withdrawal=<id>.
	const linkedTab = appPage.url.searchParams.get('tab');
	let tab = $state<Tab>(
		linkedTab === 'verifying' || linkedTab === 'completed' || linkedTab === 'closed'
			? linkedTab
			: 'action'
	);
	let selectedId = $state<string | null>(appPage.url.searchParams.get('withdrawal'));
	/** The linked withdrawal opens once even when it isn't on the first page. */
	let linked = appPage.url.searchParams.get('withdrawal');
	let detail = $state<WithdrawalType | null>(null);
	let notice = $state<string | null>(null);

	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);

	const DENIED = 'Only people who approve withdrawals see this queue.';
	async function read(path: string): Promise<PageLoaded<WithdrawalPage>> {
		const exit = await Effect.runPromiseExit(getJson(path, WithdrawalPage));
		if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		const isBackend = failure?._tag === 'BackendError';
		const denied = isBackend && failure.code === 'authorization_denied';
		return {
			ok: false,
			text: denied ? DENIED : 'We couldn’t load the queue.',
			status: isBackend ? failure.status : null
		};
	}
	const queuePath = (forTab: Tab, cursor?: string) => {
		// Built and read once per call; not reactive state.
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const params = new URLSearchParams({ tab: forTab });
		if (cursor) params.set('cursor', cursor);
		return `${WithdrawalAppRoutes.queue}?${params}`;
	};

	// Blueprint 23: each tab's first page opens from cache, then refreshes (a
	// new tab is a new `part`, so it reads again by itself). Receipt revisions
	// (receipt facts, evidence ids) are never kept; the panel reads the
	// withdrawal itself fresh (uncached) by id.
	const view = cachedPage(shell, {
		kind: 'queue',
		part: () => tab,
		load: () => read(queuePath(tab)),
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
		const forTab = tab;
		return pages.more((cursor) => read(queuePath(forTab, cursor)));
	};

	// Keep the selection (by id) when it's still listed, but always show its
	// current state. A cached list only marks the row; the panel's read waits
	// for the fresh list, as before.
	let selectedFrom: WithdrawalPage | null = null;
	$effect(() => {
		const value = view.data;
		const isFresh = view.savedAt === null;
		if (!value || value === selectedFrom) return;
		untrack(() => {
			selectedFrom = value;
			const keep = value.items.some((w) => w.withdrawalId === selectedId);
			const next = linked ?? (keep ? selectedId : (value.items[0]?.withdrawalId ?? null));
			if (!isFresh) {
				if (next !== selectedId) detail = null;
				selectedId = next;
				return;
			}
			void select(next, keep);
			linked = null;
		});
	});

	async function select(id: string | null, refresh = false) {
		selectedId = id;
		if (!refresh) detail = null;
		if (!id) return;
		const exit = await Effect.runPromiseExit(getJson(WithdrawalAppRoutes.detail(id), Withdrawal));
		if (selectedId !== id) return;
		if (Exit.isSuccess(exit)) detail = exit.value;
	}

	$effect(() => {
		void tab;
		untrack(() => (notice = null));
	});

	function changed(next: WithdrawalType | null, message?: string) {
		if (message) notice = message;
		if (next) detail = next;
		// A command that went through invalidated 'queue' (the list reads again
		// by itself); a conflict changed nothing here, so read again.
		else void view.reload();
	}

	const counts = $derived(page?.counts ?? null);
	const tabs = $derived([
		{ key: 'action' as const, label: 'Needs action', count: counts?.action, hot: true },
		{ key: 'verifying' as const, label: 'Verifying', count: counts?.verifying },
		{ key: 'completed' as const, label: 'Completed' },
		{ key: 'closed' as const, label: 'Rejected & cancelled' }
	]);
	const correcting = $derived(detail?.payout?.status === 'correction_required');
	const firstName = (w: WithdrawalType) =>
		(w.member?.name ?? w.member?.uid ?? 'The member').split(' ')[0];
	const hero = $derived.by(() => {
		if (!counts) return null;
		// Paper v4 U04–U06: the selected withdrawal's state comes first.
		if (detail?.status === 'completed') {
			return {
				pose: 'payout-done' as const,
				title: `${formatMoney(debited(detail), 'NGN')} paid out`,
				lead: `The receipt matched. ${firstName(detail)}’s balance is updated.`
			};
		}
		if (detail?.status === 'approved' && detail.payout?.status === 'rejected') {
			return {
				pose: 'income-refused' as const,
				title: 'A reviewer rejected the receipt',
				lead: `${formatMoney(detail.reserved, 'NGN')} stays reserved. Record it again or cancel.`
			};
		}
		if (
			detail?.status === 'approved' &&
			detail.payout?.status === 'verifying' &&
			checkDelayed(currentRevision(detail.payout))
		) {
			return {
				pose: 'load-error' as const,
				title: 'We couldn’t read a receipt yet',
				lead: 'We’ll keep trying. It doesn’t use your one fix.'
			};
		}
		if (tab === 'action' && correcting) {
			return {
				pose: 'queue-correction' as const,
				title: 'One receipt didn’t match',
				lead: 'You can fix it once before it goes to review'
			};
		}
		if (tab === 'action' && counts.action > 0) {
			return {
				pose: 'queue' as const,
				title: `${counts.action} ${counts.action === 1 ? 'request' : 'requests'} waiting on you`,
				lead: `${formatMoney(page?.reserved ?? '0', 'NGN')} reserved across them`
			};
		}
		if (tab === 'verifying' && counts.verifying > 0) {
			return {
				pose: 'queue-checking' as const,
				title: `Checking ${counts.verifying} ${counts.verifying === 1 ? 'receipt' : 'receipts'}`,
				lead: 'The amounts stay reserved until they match'
			};
		}
		return null;
	});
</script>

<svelte:head><title>Withdrawal queue · Elivate Wallet</title></svelte:head>

{#if denied}
	<NoAccess lead={loadError ?? undefined} />
{:else}
	<div class="mm-page">
		<QueueTabs {tabs} bind:value={tab} label="Withdrawal queue" />
		<CacheNote savedAt={view.savedAt} online={shell.online} failed={view.error !== null} />
		{#if notice}<p class="mm-notice" role="status">{notice}</p>{/if}

		{#if !page && !loadError}
			<div class="mm-skeleton" aria-hidden="true"></div>
		{:else if loadError}
			<p class="mm-empty" role="alert">{loadError}</p>
		{:else}
			<div class="mm-split">
				<div class="mm-col">
					{#if items.length === 0}
						<p class="mm-empty">
							{tab === 'action' ? 'Nothing needs you right now.' : 'Nothing here yet.'}
						</p>
					{:else}
						<div class="mm-list">
							<div class="mm-list-head" aria-hidden="true">
								<span class="wide">Member</span><span class="num">Amount</span><span class="st"
									>Status</span
								>
							</div>
							{#each items as w (w.withdrawalId)}
								{@const stage = withdrawalStage(w)}
								<button
									type="button"
									class="mm-row"
									aria-current={selectedId === w.withdrawalId ? 'true' : undefined}
									onclick={() => select(w.withdrawalId)}
								>
									<span class="mm-who">
										<span class="mm-avatar">{initials(w.member?.name, w.member?.uid ?? '')}</span>
										<span class="mm-names">
											<span class="mm-name">{w.member?.name ?? w.member?.uid}</span>
											<span class="mm-sub">{queueLine(w)}</span>
											<Pill {...stage} inline />
										</span>
									</span>
									<span class="mm-amount">{formatMoney(w.amount, 'NGN')}</span>
									<span class="mm-status"><Pill {...stage} /></span>
								</button>
							{/each}
						</div>
						{#if pages.nextCursor}
							<button
								type="button"
								class="mm-btn sm more"
								disabled={pages.loading}
								onclick={loadMore}>{pages.loading ? 'Loading…' : 'Show more'}</button
							>
							{#if pages.error}<p class="mm-empty" role="alert">{pages.error}</p>{/if}
						{/if}
					{/if}
					{#if hero}
						<RootHero pose={hero.pose} title={hero.title} lead={hero.lead} headingLevel={2} card />
					{:else if tab === 'action'}
						<div class="mm-card info">
							<p class="mm-box-title">Approving doesn’t move money</p>
							<p class="mm-note">
								It keeps the amount reserved. The member’s balance only changes once your payout
								receipt is verified.
							</p>
						</div>
					{/if}
				</div>
				{#if detail && workspaceId}
					<WithdrawalPanel
						withdrawal={detail}
						canReturn={can('record_returned_funds')}
						{workspaceId}
						canAct={shell.canAct}
						onChanged={changed}
					/>
				{/if}
			</div>
		{/if}
	</div>
{/if}

<style>
	.more {
		align-self: center;
	}

	.info {
		gap: 6px;
		padding: 20px;
	}

	@media (min-width: 768px) {
		.mm-row :global(.mm-pill.inline) {
			display: none;
		}
	}

	.mm-row :global(.mm-pill.inline) {
		align-self: flex-start;
		margin-top: 4px;
	}
</style>
