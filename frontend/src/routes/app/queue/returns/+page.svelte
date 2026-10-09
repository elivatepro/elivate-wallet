<!--
	Returned funds (W-16), Paper "App — Screens v2" W07 (desktop) / W08
	(mobile), sent for checking W09/W10. When money from a completed payout
	comes back, a leader with "record returned funds" records how much, when it
	was seen, who returned it and the proof. It goes back to the pocket it left,
	never more than what is still returnable, once an evidence reviewer clears
	it. Opened from a completed withdrawal in the queue (?withdrawal=).
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import {
		EntryAppRoutes,
		Returnable,
		ReturnedEntry,
		type Returnable as ReturnableType
	} from '#lib/contract/entries.js';
	import {
		WithdrawalAppRoutes,
		WithdrawalPage,
		type Withdrawal
	} from '#lib/contract/withdrawals.js';
	import { getJson } from '#lib/client/api.js';
	import { CommandAttempt } from '#lib/client/command-attempt.svelte.js';
	import { EntryEvidence } from '#lib/client/entry-evidence.svelte.js';
	import { submitEntry } from '#lib/client/entry-submit.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { entryMessage, localMoment, localNow } from '#lib/entries.js';
	import { groupAmount, parseAmount } from '#lib/income.js';
	import { formatMoney, isZero } from '#lib/money.js';
	import { debited, withinRequested } from '#lib/withdrawals.js';
	import RootDialog from '#lib/ui/account/RootDialog.svelte';
	import Outcome from '#lib/ui/app/Outcome.svelte';
	import OutcomeUnknown from '#lib/ui/app/OutcomeUnknown.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import EvidencePicker from '#lib/ui/money/EvidencePicker.svelte';
	import '#lib/ui/money/entry.css';

	const shell = getContext<Shell>('shell');
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);
	const naira = (a: string) => formatMoney(a, 'NGN');

	let completed = $state<Withdrawal[]>([]);
	/** The withdrawal is fixed per page (the command path); picking another reloads. */
	const withdrawalId = page.url.searchParams.get('withdrawal');
	let returnable = $state<ReturnableType | null>(null);
	let loadError = $state<string | null>(null);
	let amountText = $state('');
	let seenAt = $state(localNow());
	let returnedBy = $state('');
	let bankReference = $state('');
	let formError = $state<string | null>(null);
	let busy = $state(false);
	const evidence = new EntryEvidence();

	const attempt = new CommandAttempt({
		command: 'submit_returned_funds',
		path: EntryAppRoutes.returns(withdrawalId ?? '00000000-0000-0000-0000-000000000000'),
		method: 'POST',
		schema: ReturnedEntry,
		scope: () =>
			shell.state.kind === 'ready'
				? { uid: shell.state.view.state.uid, workspaceId: shell.state.view.workspace.membershipId }
				: null
	});
	let restored = false;
	$effect(() => {
		if (shell.state.kind === 'ready' && !restored && withdrawalId) {
			restored = true;
			void attempt.restore();
		}
	});
	/** Recovery (F-03) stays on its own locked screen, including its PIN prompt. */
	const recovering = $derived(
		attempt.state.kind === 'unknown' ||
			attempt.state.kind === 'checking' ||
			attempt.state.kind === 'resolved' ||
			(attempt.recovering && attempt.awaitingPin)
	);
	const result = $derived(attempt.state.kind === 'done' ? attempt.state.result : null);
	const failureOf = <A, E>(exit: Exit.Exit<A, E>) =>
		Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) : undefined;

	/**
	 * The linked withdrawal loads on its own (record_returned_funds is enough);
	 * the picker's list of completed withdrawals needs the queue permission and
	 * is only offered when it loads.
	 */
	async function loadCompleted() {
		if (withdrawalId) void loadReturnable(withdrawalId);
		const exit = await Effect.runPromiseExit(
			getJson(`${WithdrawalAppRoutes.queue}?tab=completed`, WithdrawalPage)
		);
		if (Exit.isSuccess(exit)) {
			completed = [...exit.value.items];
			const first = completed[0]?.withdrawalId;
			if (!withdrawalId && first) pick(first);
			return;
		}
		if (!withdrawalId) loadError = entryMessage(failureOf(exit));
	}
	let started = false;
	$effect(() => {
		if (workspaceId && !started) {
			started = true;
			void loadCompleted();
		}
	});

	async function loadReturnable(id: string) {
		returnable = null;
		formError = null;
		const exit = await Effect.runPromiseExit(getJson(EntryAppRoutes.returns(id), Returnable));
		if (Exit.isSuccess(exit)) returnable = exit.value;
		else loadError = entryMessage(failureOf(exit));
	}

	/** The command path follows the chosen withdrawal (the attempt is per page). */
	function pick(id: string) {
		if (id === withdrawalId) return;
		window.location.replace(`/app/queue/returns?withdrawal=${id}`);
	}

	const amount = $derived(parseAmount(amountText, 2));
	const remaining = $derived(returnable?.remaining ?? '0.00');
	/** Whole percent already back (exact minor units, for the bar only). */
	const share = $derived.by(() => {
		if (!returnable) return 0;
		const units = (a: string) => BigInt(a.replace('.', ''));
		const paid = units(returnable.paidOut);
		return paid > 0n ? Number((units(returnable.returned) * 100n) / paid) : 0;
	});
	const memberName = $derived(returnable?.member?.name ?? returnable?.member?.uid ?? 'the member');
	const selected = $derived(completed.find((w) => w.withdrawalId === withdrawalId) ?? null);

	function validate(): string | null {
		if (!returnable) return 'Choose the completed withdrawal.';
		if (isZero(remaining)) return 'Everything that left has already come back.';
		if (!amount) return 'Enter the amount returned.';
		if (!withinRequested(amount, null, remaining))
			return `Up to ${naira(remaining)} can come back.`;
		if (!localMoment(seenAt)) return 'Check when it was seen in the account.';
		if (!returnedBy.trim()) return 'Say who returned it.';
		if (evidence.files.length === 0) return 'Upload the proof of return.';
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
		if (!workspaceId || !returnable || !amount) return;
		formError = null;
		busy = true;
		const outcome = await submitEntry({
			attempt,
			evidence,
			kind: 'returned_funds',
			targetMembershipId: returnable.membershipId,
			workspaceId,
			body: {
				amount,
				seenAt: localMoment(seenAt),
				returnedBy: returnedBy.trim(),
				...(bankReference.trim() ? { bankReference: bankReference.trim() } : {})
			},
			summary: `${naira(amount)} returned for ${returnable.reference}`,
			...(pin ? { pin } : {})
		});
		busy = false;
		switch (outcome.kind) {
			case 'done':
			case 'unknown':
				pinOpen = false;
				return;
			case 'locked':
				return void window.location.assign('/pin/locked');
			case 'pin':
				if (pinOpen) pinTry++;
				pinError = pin ? outcome.message : null;
				pinOpen = true;
				return;
			case 'refused':
				pinOpen = false;
				formError = entryMessage(outcome.failure);
		}
	}
</script>

<svelte:head><title>Returned funds · Elivate Wallet</title></svelte:head>

{#if recovering}
	<OutcomeUnknown {attempt} noun="return" backHref="/app/queue" backLabel="Back to queue" />
{:else if result}
	<Outcome
		pose="returned-checking"
		chip="Checking proof · no balance change yet"
		title="Sent for checking"
		lead={`${naira(result.amount)} goes back to ${result.returnable.member?.name ?? 'the member'}’s ${result.pocket?.name ?? ''} pocket once the proof is verified.`}
		footnote={`${result.returnable.reference} · ${result.reference}`}
	>
		{#snippet actions()}
			<a class="out-ghost" href="/app/queue">Back to queue</a>
			<a
				class="out-primary"
				href={`/app/queue?tab=completed&withdrawal=${result.returnable.withdrawalId}`}
				>View withdrawal</a
			>
		{/snippet}
	</Outcome>
{:else}
	<header class="en-bar">
		<a href="/app/queue" aria-label="Back to queue"><ChevronLeft size={22} strokeWidth={1.8} /></a>
		<h1>Returned funds</h1>
		<span></span>
	</header>
	<div class="en-page">
		<div class="en-desktop-only">
			<RootHero
				pose="returned-funds"
				title="Money came back from a payout"
				lead="Record it with proof. It returns to the same pocket once checked."
				headingLevel={1}
				card
			/>
		</div>
		{#if returnable}
			<div class="en-mobile-only">
				<RootHero
					pose="returned-funds"
					kicker="Can still come back"
					title={naira(remaining)}
					lead={`of ${naira(returnable.paidOut)} paid out`}
					headingLevel={1}
					card
				/>
			</div>
		{/if}
		{#if loadError}
			<p class="mm-empty" role="alert">{loadError}</p>
		{:else if completed.length === 0 && !withdrawalId}
			<p class="mm-empty">No completed withdrawals yet.</p>
		{:else}
			<form
				class="en-layout"
				onsubmit={(e) => {
					e.preventDefault();
					void submit();
				}}
				novalidate
			>
				<div class="en-card">
					{#if formError}<p class="en-error" role="alert">{formError}</p>{/if}
					<div class="en-field">
						<label class="en-label" for="rtn-withdrawal">Completed withdrawal</label>
						<div class="en-box">
							<select
								id="rtn-withdrawal"
								class="en-input"
								value={withdrawalId}
								onchange={(e) => pick(e.currentTarget.value)}
							>
								{#if withdrawalId && !selected && returnable}
									<option value={withdrawalId}
										>{memberName} · {naira(returnable.paidOut)} · {returnable.reference}</option
									>
								{/if}
								{#each completed as w (w.withdrawalId)}
									<option value={w.withdrawalId}
										>{w.member?.name ?? w.member?.uid} · {naira(debited(w))} · {w.reference}</option
									>
								{/each}
							</select>
							<ChevronDown class="en-select-icon" size={16} aria-hidden="true" />
						</div>
					</div>

					<div class="en-row">
						<div class="en-field">
							<div class="en-label-row">
								<label class="en-label" for="rtn-amount">Amount returned</label>
								<span class="en-hint">Up to {naira(remaining)}</span>
							</div>
							<div class="en-box">
								<input
									id="rtn-amount"
									class="en-input"
									inputmode="decimal"
									autocomplete="off"
									placeholder="₦0.00"
									bind:value={amountText}
									onblur={() => amount && (amountText = `₦${groupAmount(amount)}`)}
								/>
								<span class="en-chip">NGN</span>
							</div>
						</div>
						<div class="en-field">
							<label class="en-label" for="rtn-seen">Seen in account</label>
							<div class="en-box">
								<input
									id="rtn-seen"
									class="en-input"
									type="datetime-local"
									max={localNow()}
									bind:value={seenAt}
								/>
							</div>
						</div>
					</div>

					<div class="en-row">
						<div class="en-field">
							<label class="en-label" for="rtn-by">Returned by</label>
							<div class="en-box">
								<input
									id="rtn-by"
									class="en-input"
									maxlength="100"
									autocomplete="off"
									placeholder={returnable?.destination.bankName ?? 'The bank'}
									bind:value={returnedBy}
								/>
							</div>
						</div>
						<div class="en-field">
							<label class="en-label" for="rtn-ref">Bank reference</label>
							<div class="en-box">
								<input
									id="rtn-ref"
									class="en-input mono"
									maxlength="100"
									autocomplete="off"
									bind:value={bankReference}
								/>
							</div>
						</div>
					</div>

					<EvidencePicker
						{evidence}
						label="Proof of return"
						addTitle="Upload the bank statement or alert"
					/>

					<div class="en-actions">
						<a class="en-ghost" href="/app/queue">Cancel</a>
						<button type="submit" class="en-primary" disabled={!shell.canAct || busy}
							>{busy ? 'Sending…' : 'Send for checking'}</button
						>
					</div>
				</div>

				{#if returnable}
					<aside class="en-side en-desktop-only" aria-label="Remaining returnable">
						<div class="en-summary">
							<div class="en-sum-block">
								<span class="en-kicker">Remaining returnable</span>
								<span class="en-big">{naira(remaining)}</span>
								<span class="bar" aria-hidden="true"><span style:width={`${share}%`}></span></span>
							</div>
							<div class="en-sum-block">
								<div class="en-line">
									<span>Paid out</span><span class="v">{naira(returnable.paidOut)}</span>
								</div>
								<div class="en-line">
									<span>Already returned</span><span class="v credit"
										>{naira(returnable.returned)}</span
									>
								</div>
								{#if !isZero(returnable.pending)}
									<div class="en-line">
										<span>Waiting for checking</span><span class="v warn"
											>{naira(returnable.pending)}</span
										>
									</div>
								{/if}
								<div class="en-line">
									<span>Goes back to</span>
									<span class="v"
										><span class="en-dot" style:background="var(--color-accent)" aria-hidden="true"
										></span>{returnable.pocket.name} · {memberName}</span
									>
								</div>
								<div class="en-line">
									<span>Paid to</span>
									<span class="v"
										>{returnable.destination.bankName ?? 'Bank'} •• {returnable.destination
											.accountLast4}</span
									>
								</div>
							</div>
						</div>
					</aside>
				{/if}
			</form>
		{/if}
	</div>
{/if}

<RootDialog
	bind:open={pinOpen}
	pose="returned-funds"
	title="Confirm with your PIN"
	summary={amount ? `${naira(amount)} back to ${memberName}, sent for checking` : undefined}
	confirmLabel="Send for checking"
	needsPin
	{pinTry}
	{busy}
	{pinError}
	onConfirm={({ pin }) => submit(pin)}
/>

<style>
	.bar {
		display: block;
		height: 6px;
		overflow: clip;
		border-radius: 999px;
		background: var(--color-raised);
	}

	.bar span {
		display: block;
		height: 100%;
		border-radius: 999px;
		background: var(--color-success);
	}
</style>
