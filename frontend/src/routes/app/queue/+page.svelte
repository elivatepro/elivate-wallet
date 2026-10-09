<!--
	Withdrawal queue (W-10), Paper "App — Screens v1" T03 (desktop) / T06
	(mobile) with the C01/C05/C07 panels: Needs action, Verifying, Completed,
	Rejected & cancelled. Lists only members this person may approve for,
	never their own. Approving doesn't move money: the amount stays reserved
	until the payout receipt matches (or a reviewer clears it).
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import {
		Withdrawal,
		WithdrawalAppRoutes,
		WithdrawalPage,
		type Withdrawal as WithdrawalType
	} from '#lib/contract/withdrawals.js';
	import { getJson } from '#lib/client/api.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { initials } from '#lib/activity.js';
	import { formatMoney } from '#lib/money.js';
	import { queueLine, withdrawalStage } from '#lib/withdrawals.js';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import Pill from '#lib/ui/money/Pill.svelte';
	import QueueTabs from '#lib/ui/money/QueueTabs.svelte';
	import WithdrawalPanel from '#lib/ui/money/WithdrawalPanel.svelte';
	import '#lib/ui/money/money.css';

	const shell = getContext<Shell>('shell');
	type Tab = 'action' | 'verifying' | 'completed' | 'closed';

	let tab = $state<Tab>('action');
	let page = $state<WithdrawalPage | null>(null);
	let items = $state<WithdrawalType[]>([]);
	let loadError = $state<string | null>(null);
	let selectedId = $state<string | null>(null);
	let detail = $state<WithdrawalType | null>(null);
	let notice = $state<string | null>(null);
	let loadingMore = $state(false);

	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);

	/** Only the newest read is applied (a slower, older tab must not win). */
	let seq = 0;
	/** A replacement first page is loading: its cursor isn't known yet. */
	let loadingFirst = $state(false);
	async function load(more = false) {
		const mine = ++seq;
		const listFor = tab;
		if (!more) loadingFirst = true;
		// Built and read once per call; not reactive state.
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const params = new URLSearchParams({ tab });
		if (more && page?.nextCursor) params.set('cursor', page.nextCursor);
		if (more) loadingMore = true;
		const exit = await Effect.runPromiseExit(
			getJson(`${WithdrawalAppRoutes.queue}?${params}`, WithdrawalPage)
		);
		loadingMore = false;
		if (mine !== seq || listFor !== tab) return;
		if (!more) loadingFirst = false;
		if (Exit.isSuccess(exit)) {
			page = exit.value;
			items = more ? [...items, ...exit.value.items] : [...exit.value.items];
			loadError = null;
			// Keep the selection when it's still listed, but always show its current state.
			if (!more) {
				const keep = items.some((w) => w.withdrawalId === selectedId);
				void select(keep ? selectedId : (items[0]?.withdrawalId ?? null), keep);
			}
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		loadError =
			failure?._tag === 'BackendError' && failure.code === 'authorization_denied'
				? 'Only people who approve withdrawals see this queue.'
				: 'We couldn’t load the queue.';
	}

	async function select(id: string | null, refresh = false) {
		selectedId = id;
		if (!refresh) detail = null;
		if (!id) return;
		const exit = await Effect.runPromiseExit(getJson(WithdrawalAppRoutes.detail(id), Withdrawal));
		if (selectedId !== id) return;
		if (Exit.isSuccess(exit)) detail = exit.value;
	}

	let loadedFor = $state<string | null>(null);
	$effect(() => {
		const key = `${workspaceId}:${tab}`;
		if (workspaceId && loadedFor !== key) {
			loadedFor = key;
			notice = null;
			void load();
		}
	});

	function changed(next: WithdrawalType | null, message?: string) {
		if (message) notice = message;
		if (next) detail = next;
		void load();
	}

	const counts = $derived(page?.counts ?? null);
	const tabs = $derived([
		{ key: 'action' as const, label: 'Needs action', count: counts?.action, hot: true },
		{ key: 'verifying' as const, label: 'Verifying', count: counts?.verifying },
		{ key: 'completed' as const, label: 'Completed' },
		{ key: 'closed' as const, label: 'Rejected & cancelled' }
	]);
	const correcting = $derived(detail?.payout?.status === 'correction_required');
	const hero = $derived.by(() => {
		if (!counts) return null;
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

<div class="mm-page">
	<QueueTabs {tabs} bind:value={tab} label="Withdrawal queue" />
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
					{#if page?.nextCursor}
						<button
							type="button"
							class="mm-btn sm more"
							disabled={loadingMore || loadingFirst}
							onclick={() => load(true)}>{loadingMore ? 'Loading…' : 'Show more'}</button
						>
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
					{workspaceId}
					canAct={shell.canAct}
					onChanged={changed}
				/>
			{/if}
		</div>
	{/if}
</div>

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
