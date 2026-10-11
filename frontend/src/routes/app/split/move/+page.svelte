<!--
	Move between pockets (W-13), Paper "App — Screens v1" B05 (desktop) / B06
	(mobile): Details → Review → Request sent (Paper v4 MV01, approved
	2026-10-09). No PIN. The amount is held in the source pocket until a leader
	approves (then it moves at once) or the request is declined or cancelled.
	Debt can only receive what it owes. My open requests, with Cancel, are
	listed under the form.
-->
<script lang="ts">
	import { getContext, untrack } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import type { Currency } from '#lib/contract/ledger.js';
	import {
		PocketTransfer,
		TransferChoices,
		TransferPage,
		WithdrawalAppRoutes,
		type PocketTransfer as Transfer,
		type TransferChoice
	} from '#lib/contract/withdrawals.js';
	import { getJson, newKey } from '#lib/client/api.js';
	import { loadView } from '#lib/client/org.svelte.js';
	import { cachedPage, MorePages, type PageLoaded } from '#lib/client/page-cache.svelte.js';
	import { CommandAttempt } from '#lib/client/command-attempt.svelte.js';
	import { sendCommand } from '#lib/client/api.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { groupAmount, parseAmount } from '#lib/income.js';
	import { formatMoney, isZero, sumMoney } from '#lib/money.js';
	import { isUnknownOutcome } from '#lib/recovery.js';
	import { moveMessage, moveTitle, transferStage, withinRequested } from '#lib/withdrawals.js';
	import Outcome from '#lib/ui/app/Outcome.svelte';
	import OutcomeUnknown from '#lib/ui/app/OutcomeUnknown.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import Pill from '#lib/ui/money/Pill.svelte';
	import '#lib/ui/money/money.css';
	import NoAccess from '#lib/ui/app/NoAccess.svelte';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';

	const shell = getContext<Shell>('shell');
	// Same pocket colours as Pockets & split (Paper L01).
	const DOTS = [
		'var(--color-accent)',
		'var(--color-success)',
		'var(--color-info)',
		'var(--color-warning)',
		'var(--color-muted)',
		'#c9a3ff'
	];

	let denied = $state(false);
	let groupIndex = $state(0);
	let fromId = $state<string | null>(null);
	let toId = $state<string | null>(null);
	let amountText = $state('');
	let error = $state<string | null>(null);
	let step = $state<'details' | 'review'>('details');
	let notice = $state<string | null>(null);
	let cancelKey = newKey();

	const attempt = new CommandAttempt({
		command: 'request_pocket_transfer',
		path: WithdrawalAppRoutes.moves,
		method: 'POST',
		schema: PocketTransfer,
		scope: () =>
			shell.state.kind === 'ready'
				? { uid: shell.state.view.state.uid, workspaceId: shell.state.view.workspace.membershipId }
				: null
	});
	let restored = false;
	$effect(() => {
		if (shell.state.kind === 'ready' && !restored) {
			restored = true;
			void attempt.restore();
		}
	});
	const recovering = $derived(
		attempt.state.kind === 'unknown' ||
			attempt.state.kind === 'checking' ||
			attempt.state.kind === 'resolved'
	);
	const sent = $derived(attempt.state.kind === 'done' ? attempt.state.result : null);

	// Blueprint 23: the pockets to move between and my open requests open from
	// cache, then refresh (two reads, at once). Review waits for the fresh
	// pockets; the server checks the amount either way.
	async function loadChoices(): Promise<PageLoaded<TransferChoices>> {
		const exit = await Effect.runPromiseExit(getJson(WithdrawalAppRoutes.choices, TransferChoices));
		if (Exit.isSuccess(exit)) {
			denied = false;
			return { ok: true, value: exit.value };
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		denied = failure?._tag === 'BackendError' && failure.code === 'authorization_denied';
		if (denied) choicesView.clear();
		return { ok: false, text: 'We couldn’t load your pockets.', status: null };
	}
	const choicesView = cachedPage(shell, {
		kind: 'split',
		part: () => 'move-choices',
		load: loadChoices
	});
	const movesView = cachedPage(shell, {
		kind: 'split',
		part: () => 'move-open',
		load: () => loadView(`${WithdrawalAppRoutes.moves}?status=open`, TransferPage)
	});
	const morePages = new MorePages<Transfer>(() => movesView.data);
	const choices = $derived(choicesView.data);
	const mine = $derived(
		movesView.data ? { items: morePages.items, nextCursor: morePages.nextCursor } : null
	);
	const loadError = $derived(
		denied
			? 'Pocket moves aren’t open to you in this network.'
			: choicesView.data
				? null
				: choicesView.error
	);
	// The first pocket that can send, once; a choice survives fresh data replacing cached.
	$effect(() => {
		const g = choicesView.data?.groups[untrack(() => groupIndex)];
		if (!g) return;
		untrack(() => {
			fromId ??= g.pockets.find((p) => p.canSend)?.pocketId ?? null;
		});
	});

	const money = (amount: string, currency: string) =>
		currency === 'NGN' || currency === 'USD'
			? formatMoney(amount, currency as Currency)
			: `${currency} ${amount}`;
	const group = $derived(choices?.groups[groupIndex] ?? null);
	const from = $derived<TransferChoice | null>(
		group?.pockets.find((p) => p.pocketId === fromId) ?? null
	);
	const to = $derived<TransferChoice | null>(
		group?.pockets.find((p) => p.pocketId === toId) ?? null
	);
	const amount = $derived(parseAmount(amountText, 2));
	const limit = $derived(
		from && to?.maxReceive && !withinRequested(from.available, null, to.maxReceive)
			? to.maxReceive
			: (from?.available ?? null)
	);

	function review(event: SubmitEvent) {
		event.preventDefault();
		error = null;
		if (!from || !to) return void (error = 'Choose where to move from and to.');
		if (!amount) return void (error = 'Enter an amount, like 50,000.00.');
		if (limit && !withinRequested(amount, null, limit)) {
			return void (error =
				to.kind === 'debt'
					? `The Debt pocket only needs ${money(to.maxReceive ?? '0', group!.currency)}.`
					: `You can move up to ${money(from.available, group!.currency)} from ${from.name}.`);
		}
		step = 'review';
	}

	async function submit() {
		if (!from?.accountId || !to || !amount || shell.state.kind !== 'ready') return;
		error = null;
		const state = await attempt.send(
			shell.state.view.workspace.membershipId,
			{ sourceAccountId: from.accountId, destinationPocketId: to.pocketId, amount },
			{ summary: `${money(amount, group!.currency)} from ${from.name} to ${to.name}` }
		);
		if (state.kind === 'failed') {
			attempt.reset();
			error = moveMessage(state.failure);
			step = 'details';
		}
	}

	const loadingMore = $derived(morePages.loading);
	const moreMoves = () =>
		morePages.more((cursor) =>
			loadView(
				`${WithdrawalAppRoutes.moves}?status=open&cursor=${encodeURIComponent(cursor)}`,
				TransferPage
			)
		);

	async function cancel(t: Transfer) {
		if (shell.state.kind !== 'ready') return;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				WithdrawalAppRoutes.cancelMove(t.transferId),
				'POST',
				{ idempotencyKey: cancelKey },
				shell.state.view.workspace.membershipId,
				PocketTransfer
			)
		);
		if (Exit.isSuccess(exit)) {
			cancelKey = newKey();
			notice = `Cancelled. ${money(t.amount, t.currency)} is back in ${t.from.name}.`;
			void choicesView.reload();
			void movesView.reload();
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		if (failure && !isUnknownOutcome(failure)) cancelKey = newKey();
		notice = moveMessage(failure);
	}
</script>

<svelte:head><title>Move money · Elivate Wallet</title></svelte:head>

{#if recovering}
	<OutcomeUnknown
		{attempt}
		noun="pocket move"
		backHref="/app/split/move"
		backLabel="Back to pocket moves"
	/>
{:else if sent}
	<Outcome
		pose="pocket-move"
		title="Move requested"
		lead={`${money(sent.amount, sent.currency)} from ${sent.from.name} to ${sent.to.name} is held until your leader approves.`}
		footnote={sent.reference}
	>
		{#snippet actions()}
			<a class="out-ghost" href="/app/split" onclick={() => attempt.reset()}>Back to pockets</a>
			<a class="out-primary" href="/app/activity" onclick={() => attempt.reset()}>View activity</a>
		{/snippet}
	</Outcome>
{:else if denied}
	<NoAccess lead={loadError ?? undefined} />
{:else}
	<div class="mm-page">
		<h1 class="mm-title" tabindex="-1">Move between pockets</h1>
		<ol class="mm-stepper">
			<li aria-current={!sent && step === 'details' ? 'step' : undefined}>
				<span class="n">{step === 'details' && !sent ? '1' : '✓'}</span> Details
			</li>
			<li aria-current={!sent && step === 'review' ? 'step' : undefined}>
				<span class="n">{sent ? '✓' : '2'}</span> Review
			</li>
			<li aria-current={sent ? 'step' : undefined}><span class="n">3</span> Request sent</li>
		</ol>

		{#if notice}<p class="mm-notice" role="status">{notice}</p>{/if}
		<CacheNote
			savedAt={choicesView.savedAt}
			online={shell.online}
			failed={choicesView.error !== null}
		/>

		{#if !choices && !loadError}
			<div class="mm-skeleton" aria-hidden="true"></div>
		{:else if loadError || !choices}
			<p class="mm-empty" role="alert">{loadError}</p>
		{:else if !group}
			<p class="mm-empty">You don’t have pockets with money in this network yet.</p>
		{:else}
			<div class="layout">
				<form class="mm-card grow" onsubmit={review} novalidate>
					{#if error}<p class="mm-error" role="alert">{error}</p>{/if}
					{#if choices.groups.length > 1}
						<div class="mm-field">
							<label class="mm-field-label" for="mm-wallet">Wallet</label>
							<WheelPicker
								id="mm-wallet"
								class="mm-input"
								label="Wallet"
								options={choices.groups.map((g, i) => ({
									value: String(i),
									label: g.office.name,
									hint: g.currency
								}))}
								value={String(groupIndex)}
								onchange={(v) => {
									groupIndex = Number(v);
									fromId =
										choices?.groups[groupIndex]?.pockets.find((p) => p.canSend)?.pocketId ?? null;
									toId = null;
								}}
							/>
						</div>
					{/if}
					{#if step === 'details'}
						<div class="mm-field" role="radiogroup" aria-label="From pocket">
							<span class="mm-field-label">From pocket</span>
							<div class="mm-pockets">
								{#each group.pockets as p, i (p.pocketId)}
									<button
										type="button"
										role="radio"
										class="mm-pocket"
										style={`--dot: ${DOTS[i % DOTS.length]}`}
										aria-checked={fromId === p.pocketId}
										disabled={!p.canSend}
										onclick={() => {
											fromId = p.pocketId;
											if (toId === p.pocketId) toId = null;
										}}
									>
										<span class="mm-pocket-name">{p.name}</span>
										<span class="mm-pocket-sub">{money(p.available, group.currency)} available</span
										>
									</button>
								{/each}
							</div>
						</div>
						<div class="mm-field" role="radiogroup" aria-label="To pocket">
							<span class="mm-field-label">To pocket</span>
							<div class="mm-pockets">
								{#each group.pockets as p, i (p.pocketId)}
									<button
										type="button"
										role="radio"
										class="mm-pocket"
										style={`--dot: ${DOTS[i % DOTS.length]}`}
										aria-checked={toId === p.pocketId}
										disabled={p.pocketId === fromId || !p.canReceive}
										onclick={() => (toId = p.pocketId)}
									>
										<span class="mm-pocket-name">{p.name}</span>
										<span class="mm-pocket-sub"
											>{p.pocketId === fromId
												? 'Moving from here'
												: p.kind === 'debt'
													? p.maxReceive && !isZero(p.maxReceive)
														? `Owes ${money(p.maxReceive, group.currency)}`
														: 'Nothing owed'
													: `${money(p.available, group.currency)} available`}</span
										>
									</button>
								{/each}
							</div>
						</div>
						<div class="mm-field">
							<label class="mm-field-label" for="move-amount">Amount</label>
							<div class="mm-amount-box">
								<input
									id="move-amount"
									inputmode="decimal"
									autocomplete="off"
									placeholder="₦0.00"
									value={amountText}
									oninput={(e) => (amountText = e.currentTarget.value)}
									onblur={() => {
										if (amount) amountText = groupAmount(amount);
									}}
								/>
								{#if limit}
									<button
										type="button"
										class="mm-chip-btn"
										onclick={() => (amountText = groupAmount(limit))}>Use max</button
									>
								{/if}
							</div>
						</div>
						<div class="mm-actions end">
							<a class="mm-btn grow-0" href="/app/split">Cancel</a>
							<button
								type="submit"
								class="mm-btn primary grow-0"
								disabled={!shell.canAct || shell.paused('transfers') || !choicesView.fresh}
								>Continue to review</button
							>
						</div>
					{:else if from && to && amount}
						<div class="mm-field">
							<span class="mm-muted">You’re asking to move</span>
							<span class="mm-big">{money(amount, group.currency)}</span>
							<span class="mm-note">{from.name} → {to.name} · a leader approves first</span>
						</div>
						<div class="mm-actions spread">
							<button type="button" class="mm-link" onclick={() => (step = 'details')}>Edit</button>
							<button
								type="button"
								class="mm-btn primary grow-0"
								disabled={!shell.canAct ||
									shell.paused('transfers') ||
									attempt.state.kind === 'sending'}
								onclick={submit}>Send request</button
							>
						</div>
					{/if}
				</form>
				<div class="side">
					{#if from}
						<section class="mm-card changes" aria-label="What changes">
							<span class="mm-label">What changes</span>
							<div class="change">
								<span
									class="mm-pocket-name"
									style={`--dot: ${DOTS[group.pockets.findIndex((p) => p.pocketId === from.pocketId) % DOTS.length]}`}
									>{from.name}</span
								>
								<div class="mm-spread">
									<span class="mm-muted">Now</span><span class="mm-value"
										>{money(from.available, group.currency)}</span
									>
								</div>
								<div class="mm-spread">
									<span class="mm-muted">After approval</span>
									<span class="mm-value strong"
										>{money(
											amount ? sumMoney([from.available, `-${amount}`]) : from.available,
											group.currency
										)}</span
									>
								</div>
							</div>
							{#if to}
								<div class="change">
									<span
										class="mm-pocket-name"
										style={`--dot: ${DOTS[group.pockets.findIndex((p) => p.pocketId === to.pocketId) % DOTS.length]}`}
										>{to.name}</span
									>
									<div class="mm-spread">
										<span class="mm-muted">Now</span><span class="mm-value"
											>{money(to.posted, group.currency)}</span
										>
									</div>
									<div class="mm-spread">
										<span class="mm-muted">After approval</span>
										<span class="mm-value up"
											>{money(
												amount ? sumMoney([to.posted, amount]) : to.posted,
												group.currency
											)}</span
										>
									</div>
								</div>
							{/if}
						</section>
					{/if}
					<div class="art" aria-hidden="true">
						<div class="shade"></div>
						<RootImage pose="pocket-move" class="art-root" sizes="200px" />
					</div>
				</div>
			</div>
		{/if}

		{#if mine && mine.items.length > 0 && !sent}
			<section class="mm-field">
				<h2 class="mm-field-label">Waiting for approval</h2>
				<div class="mm-list">
					{#each mine.items as t (t.transferId)}
						<div class="mm-row static">
							<span class="mm-names grow">
								<span class="mm-name">{moveTitle(t)}</span>
								<span class="mm-sub">{t.reference}</span>
							</span>
							<span class="mm-amount">{money(t.amount, t.currency)}</span>
							<Pill {...transferStage(t)} />
							{#if t.can.cancel}
								<button
									type="button"
									class="mm-btn sm"
									disabled={!shell.canAct}
									onclick={() => cancel(t)}>Cancel</button
								>
							{/if}
						</div>
					{/each}
				</div>
				{#if mine.nextCursor}
					<button type="button" class="mm-btn sm more" disabled={loadingMore} onclick={moreMoves}
						>{loadingMore ? 'Loading…' : 'Show more'}</button
					>
				{/if}
			</section>
		{/if}
	</div>
{/if}

<style>
	.layout {
		display: flex;
		flex-direction: column;
		gap: 24px;
	}

	.grow {
		flex: 1;
		min-width: 0;
	}

	.grow-0 {
		flex: 0 0 auto;
	}

	.end {
		justify-content: flex-end;
	}

	.spread {
		align-items: center;
		justify-content: space-between;
	}

	.side {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.changes {
		gap: 16px;
		padding: 24px 28px;
	}

	.change {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.change + .change {
		padding-top: 16px;
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.strong {
		font-weight: var(--font-weight-semibold);
	}

	.up {
		color: var(--color-success);
		font-weight: var(--font-weight-semibold);
	}

	.art {
		position: relative;
		display: none;
		height: 220px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: var(--radius-24);
		background: #1a1d1e url('/auth-bg/desktop-dark.jpg') 70% 40% / cover;
	}

	.art .shade {
		position: absolute;
		inset: 0;
		background: linear-gradient(90deg, #111314e0 0%, #11131400 70%);
	}

	.art :global(.art-root) {
		position: absolute;
		right: 40px;
		bottom: -10px;
		width: 160px;
		height: 214px;
	}

	.static {
		cursor: default;
	}

	.more {
		align-self: center;
	}

	@media (min-width: 1024px) {
		.layout {
			flex-direction: row;
			align-items: flex-start;
		}

		.side {
			width: 360px;
			flex-shrink: 0;
		}

		.art {
			display: block;
		}
	}
</style>
