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
	import { getContext, untrack } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import {
		ReviewItem,
		ReviewPage,
		WithdrawalAppRoutes,
		type ReviewItem as ReviewItemType
	} from '#lib/contract/withdrawals.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import { cachedPage, MorePages, type PageLoaded } from '#lib/client/page-cache.svelte.js';
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
	import NoAccess from '#lib/ui/app/NoAccess.svelte';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';

	const shell = getContext<Shell>('shell');
	type Tab = 'assigned' | 'cleared' | 'rejected' | 'all';

	let tab = $state<Tab>('assigned');
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

	const DENIED = 'Only Financial Evidence Reviewers see these cases.';
	async function read(path: string): Promise<PageLoaded<ReviewPage>> {
		const exit = await Effect.runPromiseExit(getJson(path, ReviewPage));
		if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		const isBackend = failure?._tag === 'BackendError';
		const denied = isBackend && failure.code === 'authorization_denied';
		return {
			ok: false,
			text: denied ? DENIED : 'We couldn’t load the cases.',
			status: isBackend ? failure.status : null
		};
	}

	// Blueprint 23: each tab's first page opens from cache, then refreshes (a
	// new tab is a new `part`, so it reads again by itself). Receipt revisions
	// (receipt facts) and evidence files are never kept; the open case is
	// always read fresh by id.
	const view = cachedPage(shell, {
		kind: 'evidence',
		part: () => tab,
		load: () => read(`${WithdrawalAppRoutes.reviews}?tab=${tab}`),
		keep: (value) => ({
			...value,
			items: value.items.map((c) =>
				c.kind === 'payout'
					? { ...c, payout: { ...c.payout, revisions: null } }
					: { ...c, entry: { ...c.entry, evidence: [] } }
			)
		})
	});
	const pages = new MorePages<ReviewItemType>(() => view.data);
	const page = $derived(view.data);
	const items = $derived(pages.items);
	const denied = $derived(view.error === DENIED);
	const loadError = $derived(view.data ? null : view.error);
	const loadMore = () => {
		const forTab = tab;
		return pages.more((cursor) =>
			read(`${WithdrawalAppRoutes.reviews}?tab=${forTab}&cursor=${encodeURIComponent(cursor)}`)
		);
	};

	/** The open case, kept by id across refreshes; its fresh read replaces the row. */
	let selectedId = $state<string | null>(null);
	let detail = $state.raw<ReviewItemType | null>(null);
	const selected = $derived(
		detail && idOf(detail) === selectedId
			? detail
			: (items.find((c) => idOf(c) === selectedId) ?? null)
	);

	async function select(c: ReviewItemType | null) {
		reason = '';
		reasonError = null;
		error = null;
		key = newKey();
		const id = c ? idOf(c) : null;
		selectedId = id;
		detail = null;
		if (!id) return;
		const exit = await Effect.runPromiseExit(getJson(WithdrawalAppRoutes.review(id), ReviewItem));
		if (Exit.isSuccess(exit) && selectedId === id) detail = exit.value;
	}

	// A list without the open case opens its first one.
	$effect(() => {
		const value = view.data;
		if (!value) return;
		untrack(() => {
			if (!value.items.some((c) => idOf(c) === selectedId)) void select(value.items[0] ?? null);
		});
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
			// The command invalidated 'evidence': the list reads again by itself.
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		if (failure && !isUnknownOutcome(failure)) key = newKey();
		error = c.kind === 'payout' ? moveMessage(failure) : entryMessage(failure);
		if (failure?._tag === 'BackendError' && failure.code === 'conflict') void view.reload();
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

{#if denied}
	<NoAccess lead={loadError ?? undefined} />
{:else}
	<div class="mm-page">
		<QueueTabs {tabs} bind:value={tab} label="Evidence review" />
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
							{tab === 'assigned' ? 'No cases need you.' : 'Nothing here yet.'}
						</p>
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
