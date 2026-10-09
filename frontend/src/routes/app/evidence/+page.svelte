<!--
	Evidence review (W-11), Paper "App — Screens v1" C09 (desktop) / C10
	(mobile): payouts whose receipt didn't match after the one correction.
	An independent Financial Evidence Reviewer (active assignment; never the
	person who recorded the payout or whose money it is) compares what was
	recorded with what the receipt shows and clears (the withdrawal posts) or
	rejects it, always with a reason. No PIN.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import {
		ReviewCase,
		ReviewPage,
		WithdrawalAppRoutes,
		type ReviewCase as ReviewCaseType
	} from '#lib/contract/withdrawals.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { initials } from '#lib/activity.js';
	import { formatMoney } from '#lib/money.js';
	import { isUnknownOutcome } from '#lib/recovery.js';
	import {
		calendarDate,
		currentRevision,
		mismatchedFields,
		moveMessage,
		reasonText
	} from '#lib/withdrawals.js';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import Pill from '#lib/ui/money/Pill.svelte';
	import QueueTabs from '#lib/ui/money/QueueTabs.svelte';
	import '#lib/ui/money/money.css';

	const shell = getContext<Shell>('shell');
	type Tab = 'assigned' | 'cleared' | 'rejected' | 'all';

	let tab = $state<Tab>('assigned');
	let page = $state<ReviewPage | null>(null);
	let items = $state<ReviewCaseType[]>([]);
	let loadError = $state<string | null>(null);
	let selected = $state<ReviewCaseType | null>(null);
	let reason = $state('');
	let reasonError = $state<string | null>(null);
	let error = $state<string | null>(null);
	let busy = $state(false);
	let notice = $state<string | null>(null);
	let key = newKey();

	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);

	/** Only the newest read is applied (a slower, older tab must not win). */
	let seq = 0;
	/** A replacement first page is loading: its cursor isn't known yet. */
	let loadingFirst = $state(false);
	let loadingMore = $state(false);
	async function load(more = false) {
		const mine = ++seq;
		const listFor = tab;
		if (!more) loadingFirst = true;
		const cursor = more && page?.nextCursor ? `&cursor=${encodeURIComponent(page.nextCursor)}` : '';
		if (more) loadingMore = true;
		const exit = await Effect.runPromiseExit(
			getJson(`${WithdrawalAppRoutes.reviews}?tab=${tab}${cursor}`, ReviewPage)
		);
		loadingMore = false;
		if (mine !== seq || listFor !== tab) return;
		if (!more) loadingFirst = false;
		if (Exit.isSuccess(exit)) {
			page = exit.value;
			items = more ? [...items, ...exit.value.items] : [...exit.value.items];
			loadError = null;
			if (!more && !items.some((c) => c.payoutId === selected?.payoutId))
				void select(items[0] ?? null);
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		loadError =
			failure?._tag === 'BackendError' && failure.code === 'authorization_denied'
				? 'Only Financial Evidence Reviewers see these cases.'
				: 'We couldn’t load the cases.';
	}

	async function select(c: ReviewCaseType | null) {
		reason = '';
		reasonError = null;
		error = null;
		key = newKey();
		selected = c;
		if (!c) return;
		const exit = await Effect.runPromiseExit(
			getJson(WithdrawalAppRoutes.review(c.payoutId), ReviewCase)
		);
		if (Exit.isSuccess(exit) && selected?.payoutId === c.payoutId) selected = exit.value;
	}

	let loadedFor = $state<string | null>(null);
	$effect(() => {
		const k = `${workspaceId}:${tab}`;
		if (workspaceId && loadedFor !== k) {
			loadedFor = k;
			void load();
		}
	});

	async function decide(decision: 'clear' | 'reject') {
		if (!selected || !workspaceId) return;
		const trimmed = reason.trim();
		if (trimmed.length < 3 || trimmed.length > 500) {
			reasonError = 'Give a reason (3–500 characters).';
			return;
		}
		reasonError = null;
		busy = true;
		error = null;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				WithdrawalAppRoutes.decide(selected.payoutId),
				'POST',
				{ decision, reason: trimmed, idempotencyKey: key },
				workspaceId,
				ReviewCase
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			notice =
				decision === 'clear'
					? `Cleared. ${formatMoney(selected.withdrawal.amount, 'NGN')} is posted as paid.`
					: 'Rejected. The approver can record a new payout.';
			key = newKey();
			void load();
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		if (failure && !isUnknownOutcome(failure)) key = newKey();
		error = moveMessage(failure);
		if (failure?._tag === 'BackendError' && failure.code === 'conflict') void load();
	}

	const counts = $derived(page?.counts ?? null);
	const tabs = $derived([
		{ key: 'assigned' as const, label: 'Assigned to you', count: counts?.assigned, hot: true },
		{ key: 'cleared' as const, label: 'Cleared', count: counts?.cleared },
		{ key: 'rejected' as const, label: 'Rejected' },
		{ key: 'all' as const, label: 'All cases' }
	]);
	const rev = $derived(selected ? currentRevision(selected.payout) : null);
	const facts = $derived(rev?.check?.facts ?? null);
	const reasons = $derived(rev?.check?.reasons ?? []);
	const bad = $derived(mismatchedFields(reasons));
	const stageOf = (c: ReviewCaseType) =>
		c.payout.review?.decision === 'clear'
			? { label: 'Cleared', tone: 'success' as const }
			: c.payout.review?.decision === 'reject'
				? { label: 'Rejected', tone: 'danger' as const }
				: { label: 'Needs review', tone: 'warning' as const };
	const when = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(
			new Date(iso)
		);
	const naira = (a: string) => formatMoney(a, 'NGN');
</script>

<svelte:head><title>Evidence review · Elivate Wallet</title></svelte:head>

<div class="mm-page">
	<QueueTabs {tabs} bind:value={tab} label="Evidence review" />
	{#if notice}<p class="mm-notice" role="status">{notice}</p>{/if}

	{#if !page && !loadError}
		<div class="mm-skeleton" aria-hidden="true"></div>
	{:else if loadError}
		<p class="mm-empty" role="alert">{loadError}</p>
	{:else}
		<div class="mm-split">
			<div class="mm-col">
				{#if items.length === 0}
					<p class="mm-empty">{tab === 'assigned' ? 'No cases need you.' : 'Nothing here yet.'}</p>
				{:else}
					<div class="mm-list">
						<div class="mm-list-head" aria-hidden="true">
							<span class="wide">Case</span><span class="num">Amount</span><span class="st"
								>Status</span
							>
						</div>
						{#each items as c (c.payoutId)}
							{@const stage = stageOf(c)}
							<button
								type="button"
								class="mm-row"
								aria-current={selected?.payoutId === c.payoutId ? 'true' : undefined}
								onclick={() => select(c)}
							>
								<span class="mm-who">
									<span class="mm-avatar"
										>{initials(c.withdrawal.member?.name, c.withdrawal.member?.uid ?? '')}</span
									>
									<span class="mm-names">
										<span class="mm-name"
											>{c.withdrawal.member?.name ?? c.withdrawal.member?.uid}</span
										>
										<span class="mm-sub"
											>Payout receipt · {c.payout.revision === 2
												? '2nd mismatch'
												: 'mismatch'}</span
										>
										<Pill {...stage} inline />
									</span>
								</span>
								<span class="mm-amount">{naira(c.withdrawal.amount)}</span>
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
				{#if tab === 'assigned' && counts?.assigned}
					<RootHero
						pose="evidence-review"
						title={`${counts.assigned} ${counts.assigned === 1 ? 'case needs' : 'cases need'} your decision`}
						lead="Nothing posts until you clear it"
						headingLevel={2}
						card
					/>
				{/if}
			</div>

			{#if selected && rev}
				<section class="mm-panel" aria-label="Case {selected.withdrawal.reference}">
					<div class="mm-section top">
						<div class="mm-spread">
							<Pill {...stageOf(selected)} />
							<span class="mm-ref">{selected.withdrawal.reference}</span>
						</div>
						<div class="mm-spread base">
							<span class="mm-big">{naira(selected.withdrawal.amount)}</span>
							<span class="mm-muted"
								>payout to {selected.withdrawal.destination.bankName ?? 'bank'}</span
							>
						</div>
					</div>
					<div class="mm-section">
						<div class="mm-spread who">
							<span class="mm-avatar lg"
								>{initials(
									selected.withdrawal.member?.name,
									selected.withdrawal.member?.uid ?? ''
								)}</span
							>
							<div class="mm-names grow">
								<span class="mm-box-title"
									>{selected.withdrawal.member?.name ?? selected.withdrawal.member?.uid}</span
								>
								<span class="mm-box-sub"
									>Recorded by {selected.payout.submittedBy?.name ??
										selected.payout.submittedBy?.uid}</span
								>
							</div>
						</div>
					</div>
					<div class="mm-section">
						<div class="mm-compare">
							<span></span><span class="h">Recorded</span><span class="h">Receipt shows</span>
							<span class="k" class:row-bad={bad.has('amount')}>Amount</span>
							<span class:row-bad={bad.has('amount')}>{naira(rev.amount)}</span>
							<span class:row-bad={bad.has('amount')} class={bad.has('amount') ? 'bad' : 'ok'}
								>{facts?.amount ? naira(facts.amount) : '—'}</span
							>
							<span class="k" class:row-bad={bad.has('name')}>Name</span>
							<span class:row-bad={bad.has('name')}
								>{selected.withdrawal.destination.accountName}</span
							>
							<span class:row-bad={bad.has('name')} class={bad.has('name') ? 'bad' : 'ok'}
								>{facts?.recipientName ?? '—'}</span
							>
							<span class="k" class:row-bad={bad.has('date')}>Date paid</span>
							<span class:row-bad={bad.has('date')}>{calendarDate(rev.paidOn)}</span>
							<span class:row-bad={bad.has('date')} class={bad.has('date') ? 'bad' : 'ok'}
								>{facts?.transactionDate ?? '—'}</span
							>
							<span class="k" class:row-bad={bad.has('account')}>Account</span>
							<span class:row-bad={bad.has('account')}
								>•• {selected.withdrawal.destination.accountLast4}</span
							>
							<span class:row-bad={bad.has('account')} class={bad.has('account') ? 'bad' : 'ok'}
								>{facts?.recipientAccount ? `•• ${facts.recipientAccount.slice(-4)}` : '—'}</span
							>
						</div>
						<ul class="reasons">
							{#each reasons as r (r)}<li>{reasonText(r)}</li>{/each}
						</ul>
					</div>
					<div class="mm-section">
						<span class="mm-label">Receipt</span>
						<div class="mm-box">
							<div class="mm-names">
								<a
									class="mm-box-title receipt-link"
									href={WithdrawalAppRoutes.receipt(selected.payoutId, rev.revision)}
									target="_blank"
									rel="noopener">{rev.receipt.name}</a
								>
								<span class="mm-box-sub"
									>{rev.revision === 2 ? '2nd attempt · ' : ''}{rev.check?.finishedAt
										? `checked ${when(rev.check.finishedAt)}`
										: ''}</span
								>
							</div>
							<Pill label="Didn’t match" tone="danger" />
						</div>
					</div>
					{#if selected.canDecide}
						<div class="mm-section">
							<div class="mm-spread">
								<label class="mm-field-label" for="review-reason">Reason</label>
								<span class="mm-muted small">Required</span>
							</div>
							<textarea
								id="review-reason"
								class="mm-input area"
								rows="3"
								maxlength="500"
								placeholder="Why are you clearing or rejecting this?"
								aria-invalid={reasonError ? 'true' : undefined}
								bind:value={reason}></textarea>
							{#if reasonError}<p class="mm-error" role="alert">{reasonError}</p>{/if}
							{#if error}<p class="mm-error" role="alert">{error}</p>{/if}
							<div class="mm-actions">
								<button
									type="button"
									class="mm-btn"
									disabled={!shell.canAct || busy}
									onclick={() => decide('reject')}>Reject</button
								>
								<button
									type="button"
									class="mm-btn primary"
									disabled={!shell.canAct || busy}
									onclick={() => decide('clear')}>Clear</button
								>
							</div>
						</div>
					{:else if selected.payout.review}
						<div class="mm-section">
							<div class="mm-spread">
								<span class="mm-muted"
									>{selected.payout.review.decision === 'clear' ? 'Cleared' : 'Rejected'} by {selected
										.payout.review.reviewer?.name ?? selected.payout.review.reviewer?.uid}</span
								>
								<span class="mm-value">{when(selected.payout.review.decidedAt)}</span>
							</div>
							<p class="mm-note">“{selected.payout.review.reason}”</p>
						</div>
					{/if}
				</section>
			{/if}
		</div>
	{/if}
</div>

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

	.small {
		font-size: 13px;
	}

	.area {
		height: auto;
		padding: 12px 14px;
		resize: vertical;
	}

	.reasons {
		margin: 0;
		padding-left: 18px;
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	.receipt-link {
		color: var(--color-text);
		text-decoration: none;
	}

	.receipt-link:hover {
		text-decoration: underline;
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
