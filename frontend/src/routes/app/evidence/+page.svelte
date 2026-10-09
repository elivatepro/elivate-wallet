<!--
	Evidence review (W-11), Paper "App — Screens v1" C09 (desktop) / C10
	(mobile): payouts whose receipt didn't match after the one correction, and
	(Blueprint 12) conversions, adjustments and returned funds, which come here
	straight away. An independent Financial Evidence Reviewer (active
	assignment; never the person who submitted it or whose money it is)
	compares what was recorded with the evidence and clears (it posts) or
	rejects it, always with a reason. No PIN.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import {
		ReviewItem,
		ReviewPage,
		WithdrawalAppRoutes,
		type ReviewItem as ReviewItemType
	} from '#lib/contract/withdrawals.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { initials } from '#lib/activity.js';
	import { entryMessage, entryStage, entryTitle, signedEntryAmount } from '#lib/entries.js';
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
	import EntryFacts from '#lib/ui/money/EntryFacts.svelte';
	import Pill from '#lib/ui/money/Pill.svelte';
	import QueueTabs from '#lib/ui/money/QueueTabs.svelte';
	import '#lib/ui/money/money.css';

	const shell = getContext<Shell>('shell');
	type Tab = 'assigned' | 'cleared' | 'rejected' | 'all';

	let tab = $state<Tab>('assigned');
	let page = $state<ReviewPage | null>(null);
	let items = $state<ReviewItemType[]>([]);
	let loadError = $state<string | null>(null);
	let selected = $state<ReviewItemType | null>(null);
	const idOf = (c: ReviewItemType) => (c.kind === 'payout' ? c.payoutId : c.caseId);
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
			if (!more && !items.some((c) => selected && idOf(c) === idOf(selected)))
				void select(items[0] ?? null);
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		loadError =
			failure?._tag === 'BackendError' && failure.code === 'authorization_denied'
				? 'Only Financial Evidence Reviewers see these cases.'
				: 'We couldn’t load the cases.';
	}

	async function select(c: ReviewItemType | null) {
		reason = '';
		reasonError = null;
		error = null;
		key = newKey();
		selected = c;
		if (!c) return;
		const exit = await Effect.runPromiseExit(
			getJson(WithdrawalAppRoutes.review(idOf(c)), ReviewItem)
		);
		if (Exit.isSuccess(exit) && selected && idOf(selected) === idOf(c)) selected = exit.value;
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
		const c = selected;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				WithdrawalAppRoutes.decide(idOf(c)),
				'POST',
				{
					...(c.kind === 'payout' ? {} : { kind: c.kind }),
					decision,
					reason: trimmed,
					idempotencyKey: key
				},
				workspaceId,
				ReviewItem
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			notice =
				c.kind === 'payout'
					? decision === 'clear'
						? `Cleared. ${formatMoney(c.withdrawal.amount, 'NGN')} is posted as paid.`
						: 'Rejected. The approver can record a new payout.'
					: decision === 'clear'
						? `Cleared. ${c.entry.reference} is posted.`
						: `Rejected. Nothing posts for ${c.entry.reference}.`;
			key = newKey();
			void load();
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		if (failure && !isUnknownOutcome(failure)) key = newKey();
		error = c.kind === 'payout' ? moveMessage(failure) : entryMessage(failure);
		if (failure?._tag === 'BackendError' && failure.code === 'conflict') void load();
	}

	const counts = $derived(page?.counts ?? null);
	const tabs = $derived([
		{ key: 'assigned' as const, label: 'Assigned to you', count: counts?.assigned, hot: true },
		{ key: 'cleared' as const, label: 'Cleared', count: counts?.cleared },
		{ key: 'rejected' as const, label: 'Rejected' },
		{ key: 'all' as const, label: 'All cases' }
	]);
	const payoutCase = $derived(selected?.kind === 'payout' ? selected : null);
	const entryCase = $derived(selected && selected.kind !== 'payout' ? selected : null);
	const rev = $derived(payoutCase ? currentRevision(payoutCase.payout) : null);
	const facts = $derived(rev?.check?.facts ?? null);
	const reasons = $derived(rev?.check?.reasons ?? []);
	const bad = $derived(mismatchedFields(reasons));
	const stageOf = (c: ReviewItemType) =>
		c.kind !== 'payout'
			? entryStage(c.status)
			: c.payout.review?.decision === 'clear'
				? { label: 'Cleared', tone: 'success' as const }
				: c.payout.review?.decision === 'reject'
					? { label: 'Rejected', tone: 'danger' as const }
					: { label: 'Needs review', tone: 'warning' as const };
	const memberOf = (c: ReviewItemType) =>
		c.kind === 'payout' ? c.withdrawal.member : c.entry.member;
	const subOf = (c: ReviewItemType) =>
		c.kind === 'payout'
			? `Payout receipt · ${c.payout.revision === 2 ? '2nd mismatch' : 'mismatch'}`
			: entryTitle(c.entry);
	const amountOf = (c: ReviewItemType) =>
		c.kind === 'payout'
			? naira(c.withdrawal.amount)
			: c.kind === 'adjustment'
				? signedEntryAmount(c.entry)
				: formatMoney(c.entry.amount, c.entry.currency);
	const when = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(
			new Date(iso)
		);
	const naira = (a: string) => formatMoney(a, 'NGN');
</script>

<svelte:head><title>Evidence review · Elivate Wallet</title></svelte:head>

{#snippet decideBlock()}
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
{/snippet}

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
						{#each items as c (idOf(c))}
							{@const stage = stageOf(c)}
							{@const member = memberOf(c)}
							<button
								type="button"
								class="mm-row"
								aria-current={selected && idOf(selected) === idOf(c) ? 'true' : undefined}
								onclick={() => select(c)}
							>
								<span class="mm-who">
									<span class="mm-avatar">{initials(member?.name, member?.uid ?? '')}</span>
									<span class="mm-names">
										<span class="mm-name">{member?.name ?? member?.uid}</span>
										<span class="mm-sub">{subOf(c)}</span>
										<Pill {...stage} inline />
									</span>
								</span>
								<span class="mm-amount">{amountOf(c)}</span>
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

			{#if payoutCase && rev}
				<section class="mm-panel" aria-label="Case {payoutCase.withdrawal.reference}">
					<div class="mm-section top">
						<div class="mm-spread">
							<Pill {...stageOf(payoutCase)} />
							<span class="mm-ref">{payoutCase.withdrawal.reference}</span>
						</div>
						<div class="mm-spread base">
							<span class="mm-big">{naira(payoutCase.withdrawal.amount)}</span>
							<span class="mm-muted"
								>payout to {payoutCase.withdrawal.destination.bankName ?? 'bank'}</span
							>
						</div>
					</div>
					<div class="mm-section">
						<div class="mm-spread who">
							<span class="mm-avatar lg"
								>{initials(
									payoutCase.withdrawal.member?.name,
									payoutCase.withdrawal.member?.uid ?? ''
								)}</span
							>
							<div class="mm-names grow">
								<span class="mm-box-title"
									>{payoutCase.withdrawal.member?.name ?? payoutCase.withdrawal.member?.uid}</span
								>
								<span class="mm-box-sub"
									>Recorded by {payoutCase.payout.submittedBy?.name ??
										payoutCase.payout.submittedBy?.uid}</span
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
								>{payoutCase.withdrawal.destination.accountName}</span
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
								>•• {payoutCase.withdrawal.destination.accountLast4}</span
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
									href={WithdrawalAppRoutes.receipt(payoutCase.payoutId, rev.revision)}
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
					{#if payoutCase.canDecide}
						{@render decideBlock()}
					{:else if payoutCase.payout.review}
						<div class="mm-section">
							<div class="mm-spread">
								<span class="mm-muted"
									>{payoutCase.payout.review.decision === 'clear' ? 'Cleared' : 'Rejected'} by {payoutCase
										.payout.review.reviewer?.name ?? payoutCase.payout.review.reviewer?.uid}</span
								>
								<span class="mm-value">{when(payoutCase.payout.review.decidedAt)}</span>
							</div>
							<p class="mm-note">“{payoutCase.payout.review.reason}”</p>
						</div>
					{/if}
				</section>
			{:else if entryCase}
				<section class="mm-panel" aria-label="Case {entryCase.entry.reference}">
					<div class="mm-section top">
						<div class="mm-spread">
							<Pill {...stageOf(entryCase)} />
							<span class="mm-ref">{entryCase.entry.reference}</span>
						</div>
						<div class="mm-spread base">
							<span class="mm-big">{amountOf(entryCase)}</span>
							<span class="mm-muted">{entryTitle(entryCase.entry)}</span>
						</div>
					</div>
					<EntryFacts entry={entryCase.entry} returnable={entryCase.returnable} />
					{#if entryCase.canDecide}
						{@render decideBlock()}
					{:else if entryCase.entry.review}
						<div class="mm-section">
							<div class="mm-spread">
								<span class="mm-muted"
									>{entryCase.entry.review.decision === 'clear' ? 'Cleared' : 'Rejected'} by {entryCase
										.entry.review.reviewer?.name ?? entryCase.entry.review.reviewer?.uid}</span
								>
								<span class="mm-value">{when(entryCase.entry.review.decidedAt)}</span>
							</div>
							<p class="mm-note">“{entryCase.entry.review.reason}”</p>
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
