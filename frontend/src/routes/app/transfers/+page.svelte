<!--
	Pocket moves waiting on a leader (W-13), Paper "App — Screens v2" W05
	(desktop) / W06 (mobile): Waiting on you, History. Approving posts the
	move at once (no PIN); rejecting needs a reason and releases the hold.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ArrowRight from '@lucide/svelte/icons/arrow-right';
	import { PocketTransfer, TransferPage, WithdrawalAppRoutes } from '#lib/contract/withdrawals.js';
	import type { Currency } from '#lib/contract/ledger.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { initials } from '#lib/activity.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import { formatMoney } from '#lib/money.js';
	import { isUnknownOutcome } from '#lib/recovery.js';
	import { moveMessage, moveTitle, transferStage } from '#lib/withdrawals.js';
	import RootDialog from '#lib/ui/account/RootDialog.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import Pill from '#lib/ui/money/Pill.svelte';
	import QueueTabs from '#lib/ui/money/QueueTabs.svelte';
	import '#lib/ui/money/money.css';

	const shell = getContext<Shell>('shell');
	type Tab = 'waiting' | 'history';

	let tab = $state<Tab>('waiting');
	let page = $state<TransferPage | null>(null);
	let loadError = $state<string | null>(null);
	let selectedId = $state<string | null>(null);
	let busy = $state(false);
	let error = $state<string | null>(null);
	let notice = $state<string | null>(null);
	let rejectOpen = $state(false);
	let dialogError = $state<string | null>(null);
	let key = newKey();

	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);
	let items = $state<TransferPage['items'][number][]>([]);
	let loadingMore = $state(false);
	const selected = $derived(items.find((t) => t.transferId === selectedId) ?? null);

	/** Only the newest read is applied (a slower, older tab must not win). */
	let seq = 0;
	/** A replacement first page is loading: its cursor isn't known yet. */
	let loadingFirst = $state(false);
	async function load(more = false) {
		const mine = ++seq;
		const listFor = tab;
		if (!more) loadingFirst = true;
		const cursor = more && page?.nextCursor ? `&cursor=${encodeURIComponent(page.nextCursor)}` : '';
		if (more) loadingMore = true;
		const exit = await Effect.runPromiseExit(
			getJson(`${WithdrawalAppRoutes.transfers}?tab=${tab}${cursor}`, TransferPage)
		);
		loadingMore = false;
		if (mine !== seq || listFor !== tab) return;
		if (!more) loadingFirst = false;
		if (Exit.isSuccess(exit)) {
			page = exit.value;
			items = more ? [...items, ...exit.value.items] : [...exit.value.items];
			loadError = null;
			if (!items.some((t) => t.transferId === selectedId)) {
				selectedId = items[0]?.transferId ?? null;
			}
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		loadError =
			failure?._tag === 'BackendError' && failure.code === 'authorization_denied'
				? 'Only people who approve pocket moves see this.'
				: 'We couldn’t load the pocket moves.';
	}

	let loadedFor = $state<string | null>(null);
	$effect(() => {
		const k = `${workspaceId}:${tab}`;
		if (workspaceId && loadedFor !== k) {
			loadedFor = k;
			void load();
		}
	});

	async function act(action: 'approve' | 'reject', reason?: string) {
		if (!selected || !workspaceId) return;
		busy = true;
		error = null;
		dialogError = null;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				WithdrawalAppRoutes.actTransfer(selected.transferId, action),
				'POST',
				{ ...(reason ? { reason } : {}), idempotencyKey: key },
				workspaceId,
				PocketTransfer
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			key = newKey();
			rejectOpen = false;
			notice =
				action === 'approve'
					? `Moved ${money(exit.value.amount, exit.value.currency)} from ${exit.value.from.name} to ${exit.value.to.name}.`
					: 'Declined. The hold is released.';
			void load();
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		if (failure && !isUnknownOutcome(failure)) key = newKey();
		if (rejectOpen) dialogError = moveMessage(failure);
		else error = moveMessage(failure);
		if (failure?._tag === 'BackendError' && failure.code === 'conflict') void load();
	}

	const money = (amount: string, currency: string) =>
		currency === 'NGN' || currency === 'USD'
			? formatMoney(amount, currency as Currency)
			: `${currency} ${amount}`;
	const ago = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short' }).format(new Date(iso));
	const when = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(
			new Date(iso)
		);
	const tabs = $derived([
		{ key: 'waiting' as const, label: 'Waiting on you', count: page?.counts.open, hot: true },
		{ key: 'history' as const, label: 'History' }
	]);
	const reservedLine = $derived(
		(page?.reserved ?? []).map((r) => money(r.amount, r.currency)).join(' · ')
	);
</script>

<svelte:head><title>Transfers · Elivate Wallet</title></svelte:head>

<div class="mm-page">
	<QueueTabs {tabs} bind:value={tab} label="Pocket moves" />
	{#if notice}<p class="mm-notice" role="status">{notice}</p>{/if}

	{#if !page && !loadError}
		<div class="mm-skeleton" aria-hidden="true"></div>
	{:else if loadError}
		<p class="mm-empty" role="alert">{loadError}</p>
	{:else if page}
		<div class="mm-split">
			<div class="mm-col">
				{#if items.length === 0}
					<p class="mm-empty">
						{tab === 'waiting' ? 'No pocket moves waiting.' : 'Nothing here yet.'}
					</p>
				{:else}
					<div class="mm-list">
						<div class="mm-list-head" aria-hidden="true">
							<span class="wide">Member</span><span class="num">Amount</span><span class="st"
								>Status</span
							>
						</div>
						{#each items as t (t.transferId)}
							{@const stage = transferStage(t)}
							<button
								type="button"
								class="mm-row"
								aria-current={selectedId === t.transferId ? 'true' : undefined}
								onclick={() => {
									selectedId = t.transferId;
									error = null;
									key = newKey();
								}}
							>
								<span class="mm-who">
									<span class="mm-avatar">{initials(t.member?.name, t.member?.uid ?? '')}</span>
									<span class="mm-names">
										<span class="mm-name">{t.member?.name ?? t.member?.uid}</span>
										<span class="mm-sub">{moveTitle(t)} · requested {ago(t.createdAt)}</span>
										<Pill {...stage} inline />
									</span>
								</span>
								<span class="mm-amount">{money(t.amount, t.currency)}</span>
								<span class="mm-status"><Pill {...stage} /></span>
							</button>
						{/each}
					</div>
					{#if page.nextCursor}
						<button
							type="button"
							class="mm-btn sm more"
							disabled={loadingMore || loadingFirst}
							onclick={() => load(true)}>{loadingMore ? 'Loading…' : 'Show more'}</button
						>
					{/if}
				{/if}
				{#if tab === 'waiting' && page.counts.open > 0}
					<RootHero
						pose="transfers"
						title={`${page.counts.open} pocket ${page.counts.open === 1 ? 'move' : 'moves'} waiting on you`}
						lead={`${reservedLine} reserved across them`}
						headingLevel={2}
						card
					/>
				{/if}
			</div>

			{#if selected}
				<section class="mm-panel" aria-label="Pocket move {selected.reference}">
					<div class="mm-section top">
						<div class="mm-spread">
							<Pill {...transferStage(selected)} />
							<span class="mm-ref">{selected.reference}</span>
						</div>
						<div class="mm-spread base">
							<span class="mm-big">{money(selected.amount, selected.currency)}</span>
							<span class="mm-muted">{selected.currency}</span>
						</div>
					</div>
					<div class="mm-section">
						<div class="mm-spread who">
							<span class="mm-avatar lg"
								>{initials(selected.member?.name, selected.member?.uid ?? '')}</span
							>
							<div class="mm-names grow">
								<span class="mm-box-title">{selected.member?.name ?? selected.member?.uid}</span>
								<span class="mm-box-sub">{ROLE_LABELS[selected.role]} · {selected.office.name}</span
								>
							</div>
							<a class="mm-link" href={`/app/wallets?wallet=${selected.walletId}`}>View wallet</a>
						</div>
					</div>
					<div class="mm-section">
						<div class="mm-spread">
							<span class="mm-muted">Requested</span>
							<span class="mm-value">{when(selected.createdAt)}</span>
						</div>
						{#if selected.status === 'requested'}
							<div class="mm-spread">
								<span class="mm-muted">Reserved now</span>
								<span class="mm-value held">{money(selected.reserved, selected.currency)}</span>
							</div>
						{:else if selected.decidedAt}
							<div class="mm-spread">
								<span class="mm-muted">{transferStage(selected).label}</span>
								<span class="mm-value">{when(selected.decidedAt)}</span>
							</div>
						{/if}
					</div>
					<div class="mm-section">
						<span class="mm-label">Move</span>
						<div class="move">
							<div class="mm-box col">
								<span class="mm-box-sub">From</span>
								<span class="mm-box-title dot">{selected.from.name}</span>
							</div>
							<span class="arrow" aria-hidden="true"><ArrowRight size={16} /></span>
							<div class="mm-box col">
								<span class="mm-box-sub">To</span>
								<span class="mm-box-title dot to">{selected.to.name}</span>
							</div>
						</div>
						{#if selected.decisionReason}<p class="mm-note">“{selected.decisionReason}”</p>{/if}
					</div>
					{#if selected.can.approve || selected.can.reject}
						<div class="mm-section">
							{#if error}<p class="mm-error" role="alert">{error}</p>{/if}
							<div class="mm-actions">
								<button
									type="button"
									class="mm-btn"
									disabled={!shell.canAct || busy || !selected.can.reject}
									onclick={() => {
										dialogError = null;
										rejectOpen = true;
									}}>Reject</button
								>
								<button
									type="button"
									class="mm-btn primary"
									disabled={!shell.canAct || busy || !selected.can.approve}
									onclick={() => act('approve')}>Approve &amp; move</button
								>
							</div>
						</div>
					{/if}
				</section>
			{/if}
		</div>
	{/if}
</div>

{#if selected}
	<RootDialog
		bind:open={rejectOpen}
		pose="income-refused"
		title="Decline this pocket move?"
		summary={`${money(selected.amount, selected.currency)} stays in ${selected.from.name}`}
		confirmLabel="Decline"
		tone="danger"
		needsReason
		reasonPlaceholder="Tell them why (they’ll see this)"
		{busy}
		error={dialogError}
		onConfirm={({ reason }) => act('reject', reason)}
	/>
{/if}

<style>
	.grow {
		flex: 1;
	}

	.more {
		align-self: center;
	}

	.who {
		justify-content: flex-start;
	}

	.move {
		display: flex;
		align-items: center;
		gap: 10px;
	}

	.col {
		flex: 1;
		flex-direction: column;
		align-items: flex-start;
		gap: 2px;
	}

	.dot::before {
		content: '';
		display: inline-block;
		width: 8px;
		height: 8px;
		margin-right: 8px;
		border-radius: 50%;
		background: var(--color-accent);
		vertical-align: 1px;
	}

	.dot.to::before {
		background: var(--color-success);
	}

	.arrow {
		display: flex;
		flex-shrink: 0;
		align-items: center;
		justify-content: center;
		width: 28px;
		height: 28px;
		border-radius: 50%;
		background: var(--color-raised);
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
