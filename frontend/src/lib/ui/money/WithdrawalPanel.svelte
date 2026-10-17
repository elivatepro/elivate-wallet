<!--
	Withdrawal detail panel for approvers, Paper "App — Screens v1" C01
	(requested: approve / reject) and C05 (checking receipt), and "App —
	Screens v4" U01–U07 (approved 2026-10-09): show the account number (PIN,
	U01), revealed with Hide and the record form with the optional bank fee
	(U02), the one fix of what didn't match, keeping the receipt, or a new
	receipt (U03), verified (U04), check delayed (U05), receipt rejected by the
	reviewer (U06) and cancel with reason + PIN (U07).

	PIN: tried without first; on step_up_required the PIN dialog opens and the
	same command is sent again with it (the 5-minute proof then covers the
	next steps). The full account number lives only in this component's memory
	and is dropped when another withdrawal is selected.
-->
<script lang="ts">
	import DatePicker from '#lib/ui/DatePicker.svelte';
	import { enterMovesOn } from '#lib/ui/enter-moves-on.js';
	import { Cause, Effect, Exit, Option } from 'effect';
	import Lock from '@lucide/svelte/icons/lock';
	import Upload from '@lucide/svelte/icons/upload';
	import FileText from '@lucide/svelte/icons/file-text';
	import type { ApiFailure } from '#lib/contract/errors.js';
	import {
		RevealedDestination,
		Withdrawal,
		WithdrawalAppRoutes,
		type QueueAction,
		type RevealedDestination as Revealed,
		type Withdrawal as WithdrawalType
	} from '#lib/contract/withdrawals.js';
	import { RECEIPT_MAX_BYTES } from '#lib/contract/income.js';
	import { newKey, sendCommand } from '#lib/client/api.js';
	import { uploadPayoutReceipt } from '#lib/client/income-api.js';
	import { groupAmount, localToday, parseAmount } from '#lib/income.js';
	import { initials } from '#lib/activity.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import { formatMoney } from '#lib/money.js';
	import { pinProblem } from '#lib/payout.js';
	import { isUnknownOutcome } from '#lib/recovery.js';
	import {
		calendarDate,
		checkDelayed,
		currentRevision,
		destinationTitle,
		fixLabel,
		mismatchedFields,
		moveMessage,
		progress,
		reasonText,
		withdrawalStage,
		withinRequested
	} from '#lib/withdrawals.js';
	import RootDialog from '#lib/ui/account/RootDialog.svelte';
	import Pill from './Pill.svelte';

	let {
		withdrawal,
		workspaceId,
		canAct,
		canReturn = false,
		onChanged
	}: {
		withdrawal: WithdrawalType;
		workspaceId: string;
		canAct: boolean;
		/** W-16: offers "Record returned funds" on a completed withdrawal. */
		canReturn?: boolean;
		onChanged: (next: WithdrawalType | null, notice?: string) => void;
	} = $props();

	const w = $derived(withdrawal);
	const stage = $derived(withdrawalStage(w));
	const payout = $derived(w.payout && w.payout.status !== 'rejected' ? w.payout : null);
	/** U06: the last payout record, rejected by the reviewer; the hold stays. */
	const rejected = $derived(
		w.status === 'approved' && w.payout?.status === 'rejected' ? w.payout : null
	);
	const shown = $derived(payout ?? rejected);
	const rev = $derived(currentRevision(shown));
	const delayed = $derived(payout?.status === 'verifying' && checkDelayed(rev));
	const steps = $derived(progress(w));
	const naira = (a: string) => formatMoney(a, 'NGN');
	const when = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(
			new Date(iso)
		);

	// ── Local state, reset per withdrawal ──
	let revealed = $state<Revealed | null>(null);
	let error = $state<string | null>(null);
	let busy = $state(false);
	let mode = $state<'view' | 'record' | 'correct'>('view');
	/** U03: the one fix of the mismatched fields, keeping the receipt. */
	let fixOpen = $state(false);
	let fixError = $state<string | null>(null);
	let fixPinError = $state<string | null>(null);
	let fixTry = $state(0);
	let fixKey = newKey();
	let sentText = $state('');
	let feeText = $state('');
	let paidOn = $state(localToday());
	let bankReference = $state('');
	let notes = $state('');
	let file = $state<File | null>(null);
	let progressPct = $state<number | null>(null);
	let fieldError = $state<string | null>(null);
	let formKey = newKey();
	let evidenceFor = $state<{ key: string; file: File; evidenceId: string } | null>(null);
	let fileInput: HTMLInputElement | undefined = $state();

	let lastId = '';
	$effect(() => {
		if (w.withdrawalId !== lastId) {
			lastId = w.withdrawalId;
			revealed = null;
			error = null;
			mode = 'view';
			resetForm();
		}
	});

	function resetForm(prefill = false) {
		const r = prefill ? rev : null;
		sentText = r ? `₦${groupAmount(r.amount)}` : `₦${groupAmount(w.amount)}`;
		feeText = r?.fee ? `₦${groupAmount(r.fee)}` : '';
		paidOn = r?.paidOn ?? localToday();
		bankReference = r?.bankReference ?? '';
		notes = r?.notes ?? '';
		file = null;
		evidenceFor = null;
		progressPct = null;
		fieldError = null;
		formKey = newKey();
	}

	// ── PIN dialog shared by every protected step ──
	let pinOpen = $state(false);
	let pinError = $state<string | null>(null);
	let stepTry = $state(0);
	let pinTitle = $state('');
	let pinSummary = $state('');
	let pinLabel = $state('Confirm');
	let pending: ((pin: string | undefined) => Promise<void>) | null = null;

	/** Runs `run` without a PIN; on step_up_required asks for it and runs again. */
	async function withStepUp(
		copy: { title: string; summary: string; label: string },
		run: (pin: string | undefined) => Promise<ApiFailure | null>
	) {
		error = null;
		busy = true;
		const failure = await run(undefined);
		busy = false;
		if (!failure) return;
		const problem = pinProblem(failure);
		if (problem?.kind === 'pin') {
			pinTitle = copy.title;
			pinSummary = copy.summary;
			pinLabel = copy.label;
			pinError = null;
			pending = async (pin) => {
				busy = true;
				const again = await run(pin);
				busy = false;
				if (!again) {
					pinOpen = false;
					return;
				}
				const p = pinProblem(again);
				if (p?.kind === 'locked') return void window.location.assign('/pin/locked');
				if (p) {
					stepTry++;
					return void (pinError = p.message);
				}
				pinOpen = false;
				error = moveMessage(again);
			};
			pinOpen = true;
			return;
		}
		if (problem?.kind === 'locked') return void window.location.assign('/pin/locked');
		error = moveMessage(failure);
		if (failure._tag === 'BackendError' && failure.code === 'conflict') onChanged(null);
	}

	const failureOf = (exit: Exit.Exit<unknown, ApiFailure>) =>
		Exit.isFailure(exit)
			? (Option.getOrUndefined(Cause.findErrorOption(exit.cause)) ?? null)
			: null;

	async function act(action: QueueAction, id: string, body: Record<string, unknown>) {
		return Effect.runPromiseExit(
			sendCommand(WithdrawalAppRoutes.act(id, action), 'POST', body, workspaceId, Withdrawal)
		);
	}

	// ── C01: approve / reject ──
	let approveKey = newKey();
	async function approve() {
		busy = true;
		error = null;
		const exit = await act('approve', w.withdrawalId, { idempotencyKey: approveKey });
		busy = false;
		if (Exit.isSuccess(exit)) {
			approveKey = newKey();
			return onChanged(
				exit.value,
				`Approved. ${naira(w.amount)} stays reserved until the payout is verified.`
			);
		}
		const failure = failureOf(exit);
		if (failure && !isUnknownOutcome(failure)) approveKey = newKey();
		error = moveMessage(failure ?? undefined);
		if (failure?._tag === 'BackendError' && failure.code === 'conflict') onChanged(null);
	}

	let rejectOpen = $state(false);
	let cancelOpen = $state(false);
	let dialogError = $state<string | null>(null);
	let dialogPinError = $state<string | null>(null);
	let pinTry = $state(0);
	let decisionKey = newKey();

	async function decide(action: 'reject' | 'cancel', reason: string, pin: string | undefined) {
		busy = true;
		dialogError = null;
		dialogPinError = null;
		const exit = await act(action, w.withdrawalId, {
			reason,
			...(pin ? { pin } : {}),
			idempotencyKey: decisionKey
		});
		busy = false;
		if (Exit.isSuccess(exit)) {
			rejectOpen = false;
			cancelOpen = false;
			decisionKey = newKey();
			return onChanged(
				exit.value,
				action === 'reject'
					? 'Not approved. The hold is released.'
					: 'Cancelled. The hold is released.'
			);
		}
		const failure = failureOf(exit);
		const problem = pinProblem(failure ?? undefined);
		if (problem?.kind === 'locked') return void window.location.assign('/pin/locked');
		if (problem) {
			pinTry++;
			return void (dialogPinError = problem.message);
		}
		if (failure && !isUnknownOutcome(failure)) decisionKey = newKey();
		dialogError = moveMessage(failure ?? undefined);
	}

	// ── T03: reveal ──
	function reveal() {
		void withStepUp(
			{
				title: 'Show account number',
				summary: 'Only you see it. It hides again when you leave',
				label: 'Show number'
			},
			async (pin) => {
				const exit = await Effect.runPromiseExit(
					sendCommand(
						WithdrawalAppRoutes.act(w.withdrawalId, 'reveal'),
						'POST',
						pin ? { pin } : {},
						workspaceId,
						RevealedDestination
					)
				);
				if (Exit.isSuccess(exit)) {
					revealed = exit.value;
					return null;
				}
				return failureOf(exit);
			}
		);
	}

	// ── T03 / C07: record or correct ──
	function pickFile(event: Event) {
		const input = event.currentTarget as HTMLInputElement;
		const picked = input.files?.[0] ?? null;
		input.value = '';
		if (!picked) return;
		if (picked.size > RECEIPT_MAX_BYTES)
			return void (fieldError = 'The receipt must be 10 MB or smaller.');
		if (!/^(application\/pdf|image\/(jpeg|png))$/.test(picked.type)) {
			return void (fieldError = 'Upload a PDF, JPG or PNG.');
		}
		fieldError = null;
		file = picked;
		evidenceFor = null;
	}

	function submitPayout(event: SubmitEvent) {
		event.preventDefault();
		const sent = parseAmount(sentText, 2);
		const fee = feeText.trim() ? parseAmount(feeText, 2) : null;
		if (!sent) return void (fieldError = 'Enter the amount you sent.');
		if (feeText.trim() && !fee) return void (fieldError = 'Check the fee.');
		if (!withinRequested(sent, fee, w.amount)) {
			return void (fieldError = `Amount sent plus fee can’t be more than ${naira(w.amount)}.`);
		}
		if (!/^\d{4}-\d{2}-\d{2}$/.test(paidOn) || paidOn > localToday()) {
			return void (fieldError = 'Check the date paid.');
		}
		if (!file) return void (fieldError = 'Upload the transfer receipt.');
		fieldError = null;
		const chosen = file;
		const correcting = mode === 'correct' && payout;
		void withStepUp(
			{
				title: 'Confirm with your PIN',
				summary: `${naira(sent)} sent to ${destinationTitle(w)}, checked against the receipt`,
				label: 'Submit for verification'
			},
			async (pin) => {
				// 1. The receipt, bound to this command's key (once per key and file).
				if (!evidenceFor || evidenceFor.key !== formKey || evidenceFor.file !== chosen) {
					progressPct = 0;
					const up = await Effect.runPromiseExit(
						uploadPayoutReceipt(
							{
								file: chosen,
								withdrawalId: w.withdrawalId,
								idempotencyKey: formKey,
								...(pin ? { pin } : {})
							},
							workspaceId,
							WithdrawalAppRoutes.receiptUpload(w.withdrawalId),
							(f) => (progressPct = Math.round(f * 100))
						)
					);
					progressPct = null;
					if (Exit.isFailure(up)) return failureOf(up);
					evidenceFor = { key: formKey, file: chosen, evidenceId: up.value.evidenceId };
				}
				// 2. The record (or the one correction) with the same key.
				const body = {
					amount: sent,
					...(fee ? { fee } : {}),
					paidOn,
					...(bankReference.trim() ? { bankReference: bankReference.trim() } : {}),
					...(notes.trim() ? { notes: notes.trim() } : {}),
					evidenceId: evidenceFor.evidenceId,
					...(pin ? { pin } : {}),
					idempotencyKey: formKey
				};
				const exit = correcting
					? await act('correct', payout.payoutId, body)
					: await act('payout', w.withdrawalId, body);
				if (Exit.isSuccess(exit)) {
					mode = 'view';
					resetForm();
					onChanged(
						exit.value,
						'Sent for verification. The amount stays reserved until the receipt matches.'
					);
					return null;
				}
				const failure = failureOf(exit);
				if (failure && !isUnknownOutcome(failure) && pinProblem(failure) === null) {
					formKey = newKey();
					evidenceFor = null;
				}
				return failure;
			}
		);
	}

	// ── U03: the one fix, keeping the receipt ──
	const fixFields = $derived(
		[...mismatchedFields(rev?.check?.reasons ?? [])].filter(
			(f): f is 'amount' | 'date' => f === 'amount' || f === 'date'
		)
	);
	let fixAmount = $state('');
	let fixDate = $state('');
	function openFix() {
		if (!rev) return;
		fixAmount = `₦${groupAmount(rev.amount)}`;
		fixDate = rev.paidOn;
		fixError = null;
		fixPinError = null;
		fixOpen = true;
	}

	async function sendFix(pin: string | undefined) {
		if (!payout || !rev) return;
		const amount = parseAmount(fixAmount, 2);
		if (!amount) return void (fixError = 'Enter the amount you sent.');
		if (!withinRequested(amount, rev.fee, w.amount)) {
			return void (fixError = `Amount sent plus fee can’t be more than ${naira(w.amount)}.`);
		}
		if (!/^\d{4}-\d{2}-\d{2}$/.test(fixDate) || fixDate > localToday()) {
			return void (fixError = 'Check the date paid.');
		}
		busy = true;
		fixError = null;
		fixPinError = null;
		const exit = await act('correct', payout.payoutId, {
			amount,
			...(rev.fee ? { fee: rev.fee } : {}),
			paidOn: fixDate,
			...(rev.bankReference ? { bankReference: rev.bankReference } : {}),
			...(rev.notes ? { notes: rev.notes } : {}),
			...(pin ? { pin } : {}),
			idempotencyKey: fixKey
		});
		busy = false;
		if (Exit.isSuccess(exit)) {
			fixOpen = false;
			fixKey = newKey();
			return onChanged(exit.value, 'Sent again. The receipt is checked against your fix.');
		}
		const failure = failureOf(exit);
		const problem = pinProblem(failure ?? undefined);
		if (problem?.kind === 'locked') return void window.location.assign('/pin/locked');
		if (problem) {
			fixTry++;
			return void (fixPinError = problem.message);
		}
		if (failure && !isUnknownOutcome(failure)) fixKey = newKey();
		fixError = moveMessage(failure ?? undefined);
	}

	// ── Check delayed: send it again ──
	let retryKey = newKey();
	function retryCheck() {
		if (!payout) return;
		void withStepUp(
			{
				title: 'Check the receipt again',
				summary: 'It doesn’t use your one fix',
				label: 'Check again'
			},
			async (pin) => {
				const exit = await act('retry', payout.payoutId, {
					...(pin ? { pin } : {}),
					idempotencyKey: retryKey
				});
				if (Exit.isSuccess(exit)) {
					retryKey = newKey();
					onChanged(exit.value, 'Checking the receipt again.');
					return null;
				}
				return failureOf(exit);
			}
		);
	}

	const facts = $derived(rev?.check?.facts ?? null);
	const ago = (iso: string) => {
		const minutes = Math.max(1, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
		return minutes < 60 ? `${minutes} min ago` : when(iso);
	};
	const shortDay = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short' }).format(new Date(iso));
	/** The line under the receipt name (U04 "Checked …", U05 "… we’ll try again", U06 "Rejected …"). */
	const receiptLine = $derived.by(() => {
		if (!rev || !shown) return '';
		const attempt = rev.revision === 2 ? ' · 2nd attempt' : '';
		if (shown.status === 'rejected' && shown.review) {
			const by = shown.review.reviewer?.name ?? shown.review.reviewer?.uid ?? 'the reviewer';
			return `Rejected ${shortDay(shown.review.decidedAt)} by ${by}${attempt}`;
		}
		if (delayed && rev.check?.status !== 'dead')
			return `Sent ${ago(rev.createdAt)} · we’ll try again`;
		if (rev.check?.finishedAt) return `Checked ${when(rev.check.finishedAt)}${attempt}`;
		return `Sent ${ago(rev.createdAt)}${attempt}`;
	});
	const reasons = $derived(rev?.check?.reasons ?? []);
	const bad = $derived(mismatchedFields(reasons));
	const receiptHref = (revision: number) =>
		payout ? WithdrawalAppRoutes.receipt(payout.payoutId, revision) : '#';
	const memberName = $derived(w.member?.name ?? w.member?.uid ?? 'Member');
</script>

<section class="mm-panel" aria-label="Withdrawal {w.reference}">
	<div class="mm-section top">
		<div class="mm-spread">
			<Pill
				label={payout?.status === 'correction_required'
					? 'Correction needed · 1 left'
					: stage.label}
				tone={stage.tone}
			/>
			<span class="mm-ref">{w.reference}</span>
		</div>
		<div class="mm-spread base">
			<span class="mm-big">{naira(w.amount)}</span>
			<span class="mm-muted"
				>{shown || w.status === 'completed'
					? `to ${w.destination.bankName ?? 'bank'}`
					: `from ${w.pocket.name}`}</span
			>
		</div>
		{#if w.status === 'approved' && !shown}
			<ol class="mm-steps" aria-label="Progress">
				{#each steps as s (s.label)}<li class={s.state}>{s.label}</li>{/each}
			</ol>
		{/if}
	</div>

	{#if w.status === 'requested' || (w.status === 'approved' && shown && mode === 'view') || w.status === 'completed'}
		<div class="mm-section">
			<div class="mm-spread who">
				<span class="mm-avatar lg">{initials(w.member?.name, w.member?.uid ?? '')}</span>
				<div class="mm-names grow">
					<span class="mm-box-title">{memberName}</span>
					<span class="mm-box-sub">{ROLE_LABELS[w.role]} · {w.office.name}</span>
				</div>
				<a class="mm-link" href={`/app/wallets?wallet=${w.walletId}`}>View wallet</a>
			</div>
		</div>
	{/if}

	{#if w.status === 'requested'}
		<div class="mm-section">
			<div class="mm-spread">
				<span class="mm-muted">Requested</span><span class="mm-value">{when(w.createdAt)}</span>
			</div>
			<div class="mm-spread">
				<span class="mm-muted">Reserved now</span><span class="mm-value held"
					>{naira(w.reserved)}</span
				>
			</div>
			{#if w.onBehalf}
				<div class="mm-spread">
					<span class="mm-muted">Requested by</span>
					<span class="mm-value">{w.requestedBy?.name ?? w.requestedBy?.uid}</span>
				</div>
			{/if}
		</div>
	{/if}

	{#if w.status === 'requested' || (w.status === 'approved' && (!shown || mode === 'record'))}
		<div class="mm-section">
			<span class="mm-label">Send to</span>
			<div class="mm-box">
				<div class="mm-names">
					<span class="mm-box-title">
						{#if revealed}
							{revealed.bankName ?? 'Bank'} · <span class="digits">{revealed.accountNumber}</span>
						{:else if w.status === 'approved'}
							{w.destination.bankName ?? 'Bank'} · •••••• {w.destination.accountLast4}
						{:else}
							{destinationTitle(w)}
						{/if}
					</span>
					<span class="mm-box-sub">{w.destination.accountName}</span>
				</div>
				{#if revealed}
					<button type="button" class="mm-btn sm" onclick={() => (revealed = null)}>
						<Lock size={14} /> Hide
					</button>
				{:else if w.can.reveal}
					<button type="button" class="mm-btn sm" disabled={!canAct || busy} onclick={reveal}>
						<Lock size={14} /> Reveal
					</button>
				{:else if w.status === 'requested'}
					<Pill label="Verified" tone="success" />
				{/if}
			</div>
			{#if w.status === 'approved'}
				<p class="mm-note">
					{revealed
						? 'Pay this from your bank app, then record what you sent.'
						: 'Pay this from your bank app, then record what you actually sent below.'}
				</p>
			{/if}
		</div>
	{/if}

	<!-- Blueprint 40, Paper WR02: what the withdrawal is for (none before it was asked). -->
	{#if w.reason}
		<div class="mm-section">
			<span class="mm-label">Reason</span>
			<p class="reason-quote">“{w.reason}”</p>
			<p class="reason-meta">
				{w.onBehalf
					? `Written by ${w.requestedBy?.name ?? w.requestedBy?.uid ?? 'a leader'} · `
					: ''}Requested {ago(w.createdAt)}
			</p>
		</div>
	{/if}

	{#if shown && mode === 'view' && rev}
		{#if shown.status === 'correction_required' || shown.status === 'needs_review' || shown.status === 'rejected'}
			<div class="mm-section">
				<div class="mm-compare">
					<span></span><span class="h">You recorded</span><span class="h">Receipt shows</span>
					<span class="k" class:row-bad={bad.has('amount')}>Amount</span>
					<span class:row-bad={bad.has('amount')}>{naira(rev.amount)}</span>
					<span class:row-bad={bad.has('amount')} class={bad.has('amount') ? 'bad' : 'ok'}
						>{facts?.amount ? naira(facts.amount) : '—'}</span
					>
					<span class="k" class:row-bad={bad.has('date')}>Date paid</span>
					<span class:row-bad={bad.has('date')}>{calendarDate(rev.paidOn)}</span>
					<span class:row-bad={bad.has('date')} class={bad.has('date') ? 'bad' : 'ok'}
						>{facts?.transactionDate ? calendarDate(facts.transactionDate) : '—'}</span
					>
					<span class="k" class:row-bad={bad.has('account')}>Account</span>
					<span class:row-bad={bad.has('account')}>•• {w.destination.accountLast4}</span>
					<span class:row-bad={bad.has('account')} class={bad.has('account') ? 'bad' : 'ok'}
						>{facts?.recipientAccount ? `•• ${facts.recipientAccount.slice(-4)}` : '—'}</span
					>
					{#if bad.has('name')}
						<span class="k row-bad">Name</span>
						<span class="row-bad">{w.destination.accountName}</span>
						<span class="row-bad bad">{facts?.recipientName ?? '—'}</span>
					{/if}
				</div>
				{#if reasons.length && shown.status !== 'rejected'}
					<ul class="reasons">
						{#each reasons as r (r)}<li>{reasonText(r)}</li>{/each}
					</ul>
				{/if}
			</div>
		{:else}
			<div class="mm-section">
				<div class="mm-spread">
					<span class="mm-muted">Amount sent</span><span class="mm-value">{naira(rev.amount)}</span>
				</div>
				{#if rev.fee}
					<div class="mm-spread">
						<span class="mm-muted">Bank fee</span><span class="mm-value">{naira(rev.fee)}</span>
					</div>
				{/if}
				<div class="mm-spread">
					<span class="mm-muted">Date paid</span><span class="mm-value"
						>{calendarDate(rev.paidOn)}</span
					>
				</div>
				{#if rev.bankReference}
					<div class="mm-spread">
						<span class="mm-muted">Bank reference</span><span class="mm-value mono"
							>{rev.bankReference}</span
						>
					</div>
				{/if}
			</div>
		{/if}
		<div class="mm-section">
			<span class="mm-label">Receipt</span>
			<div class="mm-box">
				<div class="mm-names">
					<a
						class="mm-box-title receipt-link"
						href={receiptHref(rev.revision)}
						target="_blank"
						rel="noopener">{rev.receipt.name}</a
					>
					<span class="mm-box-sub">{receiptLine}</span>
				</div>
				{#if shown.status === 'rejected'}
					<Pill label="Rejected" tone="danger" />
				{:else if rev.check?.status === 'dead'}
					<Pill label="Check delayed" tone="warning" />
				{:else if delayed}
					<Pill label="Retrying" tone="warning" />
				{:else if rev.check?.outcome === 'mismatch'}
					<Pill label="Didn’t match" tone="danger" />
				{:else if rev.check?.outcome === 'match'}
					<Pill label="Matched" tone="success" />
				{:else}
					<Pill label="Checking" tone="info" />
				{/if}
			</div>
			{#if shown.status === 'needs_review'}
				<p class="mm-note">
					A Financial Evidence Reviewer decides now. The amount stays reserved until then.
				</p>
			{:else if rev.check?.status === 'dead'}
				<p class="mm-note">We couldn’t read the receipt after several tries. Check it again.</p>
			{:else if shown.status === 'rejected' && shown.review}
				<p class="mm-note">“{shown.review.reason}”</p>
			{/if}
		</div>
		{#if shown.status === 'verifying' || w.status === 'completed'}
			<div class="mm-section">
				<ol class="mm-steps" aria-label="Progress">
					<li class="done">Requested</li>
					<li class="done">Approved</li>
					<li class="done">Recorded</li>
					<li class={w.status === 'completed' ? 'done' : 'current'}>
						{w.status === 'completed' ? 'Verified' : 'Checking'}
					</li>
				</ol>
			</div>
		{/if}
	{/if}

	{#if (w.status === 'approved' && !shown && w.can.record) || mode !== 'view'}
		<form class="mm-section" onsubmit={submitPayout} novalidate {@attach enterMovesOn}>
			<span class="mm-label">{mode === 'correct' ? 'New receipt' : 'Record payout'}</span>
			{#if mode === 'correct'}
				<p class="mm-note">
					This is your one fix before a reviewer looks. Upload the new receipt and correct what
					didn’t match.
				</p>
			{/if}
			<div class="two">
				<label class="mm-field">
					<span class="mm-field-label">Amount sent</span>
					<input class="mm-input" inputmode="decimal" bind:value={sentText} autocomplete="off" />
				</label>
				<div class="mm-field">
					<label class="mm-field-label" for="payout-date">Date paid</label>
					<DatePicker
						id="payout-date"
						class="mm-input"
						label="Date paid"
						max={localToday()}
						bind:value={paidOn}
					/>
				</div>
			</div>
			<label class="mm-field">
				<span class="mm-field-label">Bank reference</span>
				<input
					class="mm-input mono"
					maxlength="100"
					bind:value={bankReference}
					autocomplete="off"
				/>
			</label>
			<label class="mm-field">
				<span class="mm-field-label">Bank fee (optional)</span>
				<input
					class="mm-input"
					inputmode="decimal"
					placeholder="₦0.00"
					bind:value={feeText}
					autocomplete="off"
				/>
			</label>
			<input
				bind:this={fileInput}
				class="visually-hidden"
				type="file"
				accept="application/pdf,image/jpeg,image/png"
				onchange={pickFile}
			/>
			<button type="button" class="drop" onclick={() => fileInput?.click()}>
				{#if file}
					<FileText size={20} strokeWidth={1.6} />
					<span class="mm-box-title">{file.name}</span>
					<span class="mm-box-sub"
						>{progressPct !== null
							? `Uploading · ${progressPct}%`
							: 'Tap to choose another file'}</span
					>
				{:else}
					<Upload size={20} strokeWidth={1.6} />
					<span class="mm-box-title">Upload the transfer receipt</span>
					<span class="mm-box-sub">One receipt · PDF or image</span>
				{/if}
			</button>
			{#if fieldError}<p class="mm-error" role="alert">{fieldError}</p>{/if}
			{#if error}<p class="mm-error" role="alert">{error}</p>{/if}
			<div class="mm-actions">
				{#if mode !== 'view'}
					<button type="button" class="mm-btn" onclick={() => (mode = 'view')}>Back</button>
				{/if}
				<button type="submit" class="mm-btn primary" disabled={!canAct || busy}>
					{busy ? 'Sending…' : 'Submit for verification'}
				</button>
			</div>
			<p class="mm-note center">
				Completes only after the receipt matches. The reserved {naira(w.reserved)} stays held until then.
			</p>
		</form>
	{/if}

	{#if mode === 'view'}
		{#if error}<div class="mm-section"><p class="mm-error" role="alert">{error}</p></div>{/if}
		{#if w.can.approve || w.can.reject}
			<div class="mm-section mm-actions">
				<button
					type="button"
					class="mm-btn"
					disabled={!canAct || busy || !w.can.reject}
					onclick={() => {
						dialogError = null;
						rejectOpen = true;
					}}>Reject</button
				>
				<button
					type="button"
					class="mm-btn primary"
					disabled={!canAct || busy || !w.can.approve}
					onclick={approve}>Approve</button
				>
			</div>
		{:else if w.can.correct}
			<div class="mm-section mm-actions">
				<button
					type="button"
					class="mm-btn"
					disabled={!canAct}
					onclick={() => {
						resetForm(true);
						mode = 'correct';
					}}>New receipt</button
				>
				<button
					type="button"
					class="mm-btn primary"
					disabled={!canAct}
					onclick={() => {
						if (fixFields.length) return openFix();
						resetForm(true);
						mode = 'correct';
					}}>{fixLabel(reasons)}</button
				>
			</div>
		{:else if w.can.retryCheck}
			<div class="mm-section mm-actions">
				<button type="button" class="mm-btn primary" disabled={!canAct || busy} onclick={retryCheck}
					>Check the receipt again</button
				>
			</div>
		{:else if rejected && w.can.record}
			<div class="mm-section mm-actions">
				{#if w.can.cancel}
					<button
						type="button"
						class="mm-btn"
						disabled={!canAct}
						onclick={() => {
							dialogError = null;
							dialogPinError = null;
							cancelOpen = true;
						}}>Cancel withdrawal</button
					>
				{/if}
				<button
					type="button"
					class="mm-btn primary"
					disabled={!canAct}
					onclick={() => {
						resetForm();
						mode = 'record';
					}}>Record again</button
				>
			</div>
		{/if}
		{#if w.can.cancel && w.status === 'approved' && !shown}
			<div class="mm-section">
				<button
					type="button"
					class="mm-link danger-link"
					disabled={!canAct}
					onclick={() => {
						dialogError = null;
						dialogPinError = null;
						cancelOpen = true;
					}}>Cancel this withdrawal (no payout made)</button
				>
			</div>
		{/if}
		{#if w.status === 'completed' && canReturn}
			<div class="mm-section">
				<a class="mm-link" href={`/app/queue/returns?withdrawal=${w.withdrawalId}`}
					>Money came back? Record returned funds</a
				>
			</div>
		{/if}
		{#if w.status === 'rejected' || w.status === 'cancelled'}
			<div class="mm-section">
				<div class="mm-spread">
					<span class="mm-muted">{w.status === 'rejected' ? 'Not approved' : 'Cancelled'}</span>
					<span class="mm-value">{w.decidedAt ? when(w.decidedAt) : ''}</span>
				</div>
				{#if w.decisionReason}<p class="mm-note">“{w.decisionReason}”</p>{/if}
			</div>
		{/if}
	{/if}
</section>

<RootDialog
	bind:open={pinOpen}
	title={pinTitle}
	summary={pinSummary}
	confirmLabel={pinLabel}
	needsPin
	pinTry={stepTry}
	{busy}
	{pinError}
	onConfirm={({ pin }) => pending?.(pin)}
/>

<RootDialog
	bind:open={fixOpen}
	title={fixLabel(reasons)}
	summary="This is your one fix before a reviewer looks"
	confirmLabel="Send again"
	needsPin
	pinTry={fixTry}
	{busy}
	error={fixError}
	pinError={fixPinError}
	onConfirm={({ pin }) => sendFix(pin)}
>
	{#snippet fields()}
		{#if fixFields.includes('amount')}
			<div class="rd-field">
				<label class="rd-label" for="fix-amount">Amount sent</label>
				<input
					id="fix-amount"
					class="rd-input"
					inputmode="decimal"
					autocomplete="off"
					bind:value={fixAmount}
				/>
			</div>
		{/if}
		{#if fixFields.includes('date')}
			<div class="rd-field">
				<label class="rd-label" for="fix-date">Date paid</label>
				<DatePicker
					id="fix-date"
					class="rd-input"
					label="Date paid"
					max={localToday()}
					bind:value={fixDate}
				/>
			</div>
		{/if}
	{/snippet}
</RootDialog>

<RootDialog
	bind:open={rejectOpen}
	title="Reject this request?"
	summary={`${naira(w.amount)} goes back to ${memberName}’s ${w.pocket.name}`}
	confirmLabel="Reject request"
	tone="danger"
	needsReason
	reasonPlaceholder="Tell them why (they’ll see this)"
	{busy}
	error={dialogError}
	onConfirm={({ reason }) => decide('reject', reason, undefined)}
/>

<RootDialog
	bind:open={cancelOpen}
	title="Cancel this withdrawal"
	summary="Only if no money was sent"
	confirmLabel="Cancel withdrawal"
	cancelLabel="Keep it"
	tone="danger"
	needsReason
	needsPin
	{pinTry}
	reasonPlaceholder="Why is it being cancelled?"
	{busy}
	error={dialogError}
	pinError={dialogPinError}
	onConfirm={({ reason, pin }) => decide('cancel', reason, pin)}
/>

<style>
	/* Blueprint 40, Paper WR02. */
	.reason-quote {
		margin: 0;
		color: var(--color-text);
		font-size: var(--text-16);
		line-height: 24px;
		overflow-wrap: anywhere;
		white-space: pre-line;
	}

	.reason-meta {
		margin: 0;
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: 16px;
	}

	.grow {
		flex: 1;
	}

	.who {
		justify-content: flex-start;
	}

	.digits,
	.mono {
		font-family: var(--font-mono);
		letter-spacing: 0.02em;
	}

	.two {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 12px;
	}

	.drop {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 4px;
		padding: 18px;
		border: 1px dashed color-mix(in oklab, var(--color-accent) 50%, transparent);
		border-radius: 14px;
		background: none;
		color: var(--color-accent);
		font: inherit;
		cursor: pointer;
	}

	.drop .mm-box-title {
		color: var(--color-text);
		font-size: var(--text-14);
	}

	.receipt-link {
		color: var(--color-text);
		text-decoration: none;
	}

	.receipt-link:hover {
		text-decoration: underline;
	}

	.reasons {
		margin: 0;
		padding-left: 18px;
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	.center {
		text-align: center;
	}

	.danger-link {
		color: var(--color-danger);
		align-self: flex-start;
	}
</style>
