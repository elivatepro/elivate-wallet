<!--
	Reverse transaction (W-15), Paper "App — Screens v1" E07 (desktop) / E08
	(mobile), result "App — Screens v4" MV05. President only (protected,
	non-delegable): the exact opposite of every line of a posted transaction,
	with a reason, a note, the reference typed back and the PIN. Posts at once
	when every pocket still has that much available; otherwise nothing happens.
	A completed withdrawal is corrected with Returned funds instead.
	Opened from a transaction (?reference=) or by typing a reference: Paper
	draws no Reversals list yet, so the original-transaction card is a lookup
	until one is chosen.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ArrowDown from '@lucide/svelte/icons/arrow-down';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import X from '@lucide/svelte/icons/x';
	import {
		EntryAppRoutes,
		REVERSAL_CATEGORIES,
		Reversal,
		ReversalPreview,
		type ReversalCategory
	} from '#lib/contract/entries.js';
	import type { Currency } from '#lib/contract/ledger.js';
	import { getJson } from '#lib/client/api.js';
	import { CommandAttempt } from '#lib/client/command-attempt.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { typeLabel } from '#lib/activity.js';
	import { entryMessage, REVERSAL_LABELS } from '#lib/entries.js';
	import { formatMoney, sumMoney } from '#lib/money.js';
	import { pinProblem } from '#lib/payout.js';
	import RootDialog from '#lib/ui/account/RootDialog.svelte';
	import Outcome from '#lib/ui/app/Outcome.svelte';
	import OutcomeUnknown from '#lib/ui/app/OutcomeUnknown.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import '#lib/ui/money/entry.css';

	const shell = getContext<Shell>('shell');
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);

	let lookup = $state(page.url.searchParams.get('reference') ?? '');
	let preview = $state<ReversalPreview | null>(null);
	let lookupError = $state<string | null>(null);
	let looking = $state(false);
	let category = $state<ReversalCategory>('recorded_twice');
	let note = $state('');
	let confirm = $state('');
	let formError = $state<string | null>(null);
	let busy = $state(false);

	const attempt = new CommandAttempt({
		command: 'reverse_transaction',
		path: EntryAppRoutes.reversals,
		method: 'POST',
		schema: Reversal,
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
	/** Recovery (F-03) stays on its own locked screen, including its PIN prompt. */
	const recovering = $derived(
		attempt.state.kind === 'unknown' ||
			attempt.state.kind === 'checking' ||
			attempt.state.kind === 'resolved' ||
			// Its PIN prompt and the re-send in flight stay on the locked screen too.
			(attempt.recovering && (attempt.awaitingPin || attempt.state.kind === 'sending'))
	);
	const result = $derived(attempt.state.kind === 'done' ? attempt.state.result : null);

	async function find(event?: SubmitEvent) {
		event?.preventDefault();
		const reference = lookup.trim();
		if (!/^[A-Za-z0-9-]{11,20}$/.test(reference)) {
			lookupError = 'Type a reference like INC-7F2K-0931.';
			return;
		}
		looking = true;
		lookupError = null;
		const exit = await Effect.runPromiseExit(
			getJson(
				`${EntryAppRoutes.reversalPreview}?reference=${encodeURIComponent(reference)}`,
				ReversalPreview
			)
		);
		looking = false;
		if (Exit.isSuccess(exit)) {
			preview = exit.value;
			confirm = '';
			formError = null;
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		lookupError =
			failure?._tag === 'BackendError' && failure.code === 'authorization_denied'
				? 'Only the President reverses transactions.'
				: entryMessage(failure);
	}
	let started = false;
	$effect(() => {
		if (workspaceId && !started) {
			started = true;
			if (lookup) void find();
		}
	});

	const tx = $derived(preview?.transaction ?? null);
	/** The member-side total per currency (the original's sign). */
	const totals = $derived(
		(tx?.journals ?? []).map((j) => ({
			currency: j.currency,
			amount: sumMoney((j.lines ?? []).map((l) => l.amount))
		}))
	);
	const negate = (a: string) => (a.startsWith('-') ? a.slice(1) : `-${a}`);
	const willPost = $derived(totals.map((t) => formatMoney(negate(t.amount), t.currency, true)));
	const original = $derived(totals.map((t) => formatMoney(t.amount, t.currency, true)).join(' · '));
	const credit = $derived(!(totals[0]?.amount ?? '').startsWith('-'));
	const memberName = $derived(preview?.member?.name ?? preview?.member?.uid ?? 'the member');
	const short = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', {
			day: 'numeric',
			month: 'short',
			hour: '2-digit',
			minute: '2-digit'
		})
			.format(new Date(iso))
			.replace(' at ', ', ');
	const blockerText = $derived(
		preview?.blocker === 'already_reversed'
			? 'This transaction has already been reversed.'
			: preview?.blocker === 'not_reversible'
				? 'A completed withdrawal can’t be reversed. Record returned funds instead.'
				: null
	);
	const short_ = $derived(preview?.lines.some((l) => !l.enough) ?? false);

	function validate(): string | null {
		if (!tx) return 'Find the transaction first.';
		if (blockerText) return blockerText;
		const n = note.trim();
		if (category === 'other' && n.length < 3) return 'Add a note for “Other”.';
		if (n && (n.length < 3 || n.length > 500)) return 'The note needs 3–500 characters.';
		if (confirm.trim().toUpperCase() !== tx.reference) return `Type ${tx.reference} to confirm.`;
		return null;
	}

	let pinOpen = $state(false);
	let pinError = $state<string | null>(null);
	let pinTry = $state(0);

	/**
	 * Closing the PIN prompt drops a refused new attempt, so an edited form never
	 * resends the old body; an attempt still being recovered is always kept (F-03).
	 */
	$effect(() => {
		if (!pinOpen && attempt.awaitingPin && !attempt.recovering) attempt.reset();
	});

	async function submit(pin?: string) {
		const problem = validate();
		if (problem) return void (formError = problem);
		if (!workspaceId || !tx) return;
		formError = null;
		busy = true;
		const n = note.trim();
		const state = attempt.awaitingPin
			? await attempt.resend(pin ? { pin } : {})
			: await attempt.send(
					workspaceId,
					{
						transactionId: tx.transactionId,
						category,
						...(n ? { note: n } : {}),
						confirmReference: confirm.trim().toUpperCase()
					},
					{ ...(pin ? { pin } : {}), summary: `Reverse ${tx.reference} for ${memberName}` }
				);
		busy = false;
		if (state.kind !== 'failed') {
			pinOpen = false;
			return;
		}
		const p = pinProblem(state.failure);
		if (p?.kind === 'locked') return void window.location.assign('/pin/locked');
		if (p) {
			if (pinOpen) pinTry++;
			pinError = pin ? p.message : null;
			pinOpen = true;
			return;
		}
		pinOpen = false;
		attempt.reset();
		formError = entryMessage(state.failure);
	}

	const resultAmount = (r: Reversal) =>
		r.amounts.map((a) => formatMoney(a.amount, a.currency as Currency, true)).join(' · ');
</script>

<svelte:head><title>Reverse transaction · Elivate Wallet</title></svelte:head>

{#if recovering}
	<OutcomeUnknown
		{attempt}
		noun="reversal"
		backHref="/app/reversals"
		backLabel="Back to reversals"
	/>
{:else if result}
	<Outcome
		pose="reverse"
		title="Reversal posted"
		lead={`${resultAmount(result)} taken back from ${(result.member?.name ?? 'the member').split(' ')[0]}’s pockets.`}
		footnote={`${result.reference} · reverses ${result.reverses.reference}`}
	>
		{#snippet actions()}
			<a
				class="out-ghost"
				href={`/app/wallets?wallet=${result.walletId}&tx=${result.transactionId}`}
				>View transaction</a
			>
			<a class="out-primary" href="/app/reversals" onclick={() => attempt.reset()}
				>Back to reversals</a
			>
		{/snippet}
	</Outcome>
{:else}
	<header class="en-bar">
		<a href="/app" aria-label="Close"><X size={22} strokeWidth={1.8} /></a>
		<h1>Reverse</h1>
		<span></span>
	</header>
	<div class="en-page">
		<form
			class="en-layout"
			onsubmit={(e) => {
				e.preventDefault();
				if (tx) void submit();
				else void find();
			}}
			novalidate
		>
			<div class="en-card">
				{#if formError}<p class="en-error" role="alert">{formError}</p>{/if}
				<div class="en-field">
					<span class="en-kicker">Original transaction</span>
					{#if tx}
						<div class="original">
							<span class="icon" class:credit aria-hidden="true">
								{#if credit}<ArrowDown size={18} />{:else}<ArrowUp size={18} />{/if}
							</span>
							<span class="o-text">
								<span class="o-title"
									>{typeLabel(tx.type)}{preview?.title ? ` · ${preview.title}` : ''}</span
								>
								<span class="en-hint"
									>{memberName} · posted {short(tx.postedAt)} ·
									<span class="mono">{tx.reference}</span></span
								>
							</span>
							<span class="o-amount" class:credit>{original}</span>
						</div>
						<button
							type="button"
							class="change"
							onclick={() => {
								preview = null;
								confirm = '';
							}}>Choose another transaction</button
						>
					{:else}
						<div class="en-row">
							<div class="en-field">
								<div class="en-box">
									<input
										class="en-input mono"
										autocomplete="off"
										placeholder="INC-7F2K-0931"
										aria-label="Reference of the transaction"
										bind:value={lookup}
									/>
								</div>
							</div>
							<button type="button" class="en-ghost find" disabled={looking} onclick={() => find()}
								>{looking ? 'Finding…' : 'Find'}</button
							>
						</div>
						{#if lookupError}<p class="en-error" role="alert">{lookupError}</p>{/if}
					{/if}
				</div>

				{#if tx}
					{#if blockerText}<p class="en-notice">{blockerText}</p>{/if}
					<div class="en-field">
						<label class="en-label" for="rev-reason">Reason</label>
						<div class="en-box">
							<select id="rev-reason" class="en-input" bind:value={category}>
								{#each REVERSAL_CATEGORIES as c (c)}<option value={c}>{REVERSAL_LABELS[c]}</option
									>{/each}
							</select>
							<ChevronDown class="en-select-icon" size={16} aria-hidden="true" />
						</div>
					</div>
					<div class="en-field">
						<label class="en-label" for="rev-note">Note</label>
						<textarea
							id="rev-note"
							class="note"
							maxlength="500"
							placeholder="What happened? The member doesn’t see this."
							bind:value={note}></textarea>
					</div>
					<div class="en-field">
						<label class="en-label" for="rev-confirm">Type {tx.reference} to confirm</label>
						<div class="en-box danger">
							<input
								id="rev-confirm"
								class="en-input mono"
								autocomplete="off"
								spellcheck="false"
								bind:value={confirm}
							/>
						</div>
					</div>

					<div class="en-mobile-sum en-mobile-only">
						{#each preview?.lines ?? [] as line, i (`${line.currency}:${line.pocketId}:${i}`)}
							<div>
								<span>{line.pocket}</span>
								<span>{formatMoney(line.amount, line.currency, true)}</span>
							</div>
						{/each}
					</div>
					<button
						type="submit"
						class="en-primary danger en-mobile-only"
						disabled={!shell.canAct || busy || !!blockerText}>Reverse transaction</button
					>
				{/if}
			</div>

			{#if tx}
				<aside class="en-side en-desktop-only" aria-label="What the reversal posts">
					<div class="en-summary">
						<div class="en-sum-block">
							<span class="en-kicker">Reversal will post</span>
							<span class="en-big" class:debit={credit} class:credit={!credit}
								>{willPost.join(' · ')}</span
							>
						</div>
						<div class="en-sum-block">
							{#each preview?.lines ?? [] as line, i (`${line.currency}:${line.pocketId}:${i}`)}
								<div class="en-line">
									<span>{line.pocket} · {formatMoney(line.available, line.currency)} free</span>
									<span class="v" class:debit={!line.enough}
										>{formatMoney(line.amount, line.currency, true)}</span
									>
								</div>
							{/each}
							{#if short_}
								<p class="en-hint">
									A pocket doesn’t have enough available now; the reversal won’t post until it does.
								</p>
							{/if}
						</div>
						<div class="en-sum-block">
							<button
								type="submit"
								class="en-primary danger"
								disabled={!shell.canAct || busy || !!blockerText}>Reverse transaction</button
							>
						</div>
					</div>
					<div class="en-art en-desktop-only" aria-hidden="true">
						<div class="en-art-shade"></div>
						<div class="en-art-grain"></div>
						<RootImage pose="reverse" class="en-art-root" sizes="160px" />
					</div>
				</aside>
			{/if}
		</form>
	</div>
{/if}

<RootDialog
	bind:open={pinOpen}
	pose="reverse"
	title="Confirm with your PIN"
	summary={tx ? `Reverse ${tx.reference}. This posts at once.` : undefined}
	confirmLabel="Reverse transaction"
	tone="danger"
	needsPin
	{pinTry}
	{busy}
	{pinError}
	onConfirm={({ pin }) => submit(pin)}
/>

<style>
	.original {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 16px 18px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
	}

	.icon {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 40px;
		height: 40px;
		border-radius: 999px;
		background: color-mix(in oklab, var(--color-danger) 14%, transparent);
		color: var(--color-danger);
	}

	.icon.credit {
		background: color-mix(in oklab, var(--color-success) 14%, transparent);
		color: var(--color-success);
	}

	.o-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.o-title {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 20px;
	}

	.o-amount {
		color: var(--color-text);
		font-size: 17px;
		font-weight: var(--font-weight-semibold);
		white-space: nowrap;
	}

	.o-amount.credit {
		color: var(--color-success);
	}

	.mono {
		font-family: var(--font-mono);
	}

	.change {
		align-self: flex-start;
		border: 0;
		background: none;
		color: var(--color-muted);
		font: inherit;
		font-size: 13px;
		text-decoration: underline;
		cursor: pointer;
	}

	.find {
		flex: 0 0 auto;
		height: 56px;
	}

	.note {
		min-height: 84px;
		padding: 14px 16px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		line-height: 22px;
		resize: vertical;
	}

	.note:focus {
		outline: none;
		border-color: var(--color-accent);
	}

	.danger {
		border-color: color-mix(in oklab, var(--color-danger) 70%, transparent);
	}
</style>
