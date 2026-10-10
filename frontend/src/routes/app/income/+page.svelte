<!--
	Record income (W-08), Paper "App — Screens v4 (member build)" J01–J05
	(owner approved 2026-10-08): J01 form with the exact split preview, J02
	confirm + PIN, J03 posted, J04 checking what happened, J05 couldn't record.

	A record_income holder picks one of their members (server-side search across
	the network), the currency, the amount, source, date, optional provider
	reference and fee, 1–5 receipts and notes. "Review and post" opens J02; on
	Post income the receipts upload (with progress; bytes verified by the
	backend), then the income posts. Posting is final.

	Outcome unknown (timeout, dropped connection, reload after dispatch) shows
	J04 and locks the attempt: Check again re-sends the same key and body (it
	can never post twice); Cancel this attempt asks the backend, which answers
	with the posted income if it went through (F-03).
-->
<script lang="ts">
	import { getContext, tick, untrack } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import FileText from '@lucide/svelte/icons/file-text';
	import Plus from '@lucide/svelte/icons/plus';
	import X from '@lucide/svelte/icons/x';
	import type { ApiFailure } from '#lib/contract/errors.js';
	import {
		CancelIncomeResult,
		IncomeAppRoutes,
		IncomePosted,
		IncomeTargets,
		RECEIPT_MAX_FILES,
		type IncomeTarget,
		type RecordIncomeInput
	} from '#lib/contract/income.js';
	import { CommandOutcome, type Currency } from '#lib/contract/ledger.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import { uploadReceipt } from '#lib/client/income-api.js';
	import {
		browserAttemptStore,
		clearAttempt,
		loadAttempt,
		saveAttempt,
		type AttemptScope,
		type IncomeAttempt
	} from '#lib/client/income-attempt.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import {
		allocate,
		fieldOfFailure,
		formatSent,
		formatSize,
		groupAmount,
		incomeMessage,
		isDefinitive,
		isFormRefusal,
		isTargetRefusal,
		localToday,
		parseAmount,
		pocketColor,
		receiptProblem,
		refusalLead,
		shortPercent,
		shortPocket,
		validateDraft,
		type DraftErrors
	} from '#lib/income.js';
	import { currencySymbol, formatMoney } from '#lib/money.js';
	import { pinProblem } from '#lib/payout.js';
	import ConfirmDialog from '#lib/ui/app/ConfirmDialog.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import IncomeConfirm from '#lib/ui/income/IncomeConfirm.svelte';
	import Outcome from '#lib/ui/app/Outcome.svelte';
	import MemberPicker from '#lib/ui/income/MemberPicker.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';

	const shell = getContext<Shell>('shell');
	const KNOWN: ReadonlyArray<Currency> = ['NGN', 'USD'];

	interface Receipt {
		readonly key: string;
		readonly file: File;
		evidenceId: string | null;
		/** 0–1 while uploading, null otherwise. */
		progress: number | null;
	}

	// ── Loaded data ──
	let data = $state<IncomeTargets | null>(null);
	let targets = $state<IncomeTarget[]>([]);
	let nextCursor = $state<string | null>(null);
	let loadError = $state<string | null>(null);
	let loadingMore = $state(false);

	// ── Draft ──
	let target = $state<IncomeTarget | null>(null);
	let currency = $state<Currency>('NGN');
	let amountText = $state('');
	let source = $state('');
	const today = localToday();
	let receivedOn = $state(today);
	let notes = $state('');
	let providerReference = $state('');
	let feeText = $state('');
	let receipts = $state<Receipt[]>([]);
	let errors = $state<DraftErrors>({});
	let formError = $state<string | null>(null);
	let fileInput: HTMLInputElement | undefined = $state();
	let picker: { openPicker: () => void } | undefined = $state();
	/** One key per attempt; receipts are bound to it and to the member. */
	let commandKey = newKey();

	// ── Phases ──
	let phase = $state<'form' | 'unknown' | 'done' | 'refused'>('form');
	let attempt = $state<IncomeAttempt | null>(null);
	let result = $state<IncomePosted | null>(null);
	let resultFor = $state('');
	const activityHref = $derived(
		result?.walletId
			? `/app/wallets?wallet=${result.walletId}&view=activity&tx=${result.transactionId}`
			: '/app/wallets'
	);
	let refusal = $state<{ lead: string; aboutTarget: boolean } | null>(null);
	let busy = $state(false);
	let postOpen = $state(false);
	let recheckOpen = $state(false);
	let cancelOpen = $state(false);
	let dialogError = $state<string | null>(null);
	let pinError = $state<string | null>(null);
	let notice = $state<string | null>(null);

	const ready = $derived(shell.state.kind === 'ready' ? shell.state : null);
	const liveScope = $derived<AttemptScope | null>(
		ready ? { uid: ready.view.state.uid, workspaceId: ready.view.workspace.membershipId } : null
	);
	/**
	 * The person + workspace this page was opened for. Every command, upload and
	 * stored attempt is bound to it; if the shell later switches (another tab),
	 * the page reloads instead of sending an attempt under the wrong workspace.
	 */
	let scope = $state<AttemptScope | null>(null);
	const workspaceId = $derived(scope?.workspaceId ?? null);
	const allowed = $derived(
		!!ready && (ready.view.capabilities?.permissions ?? []).includes('record_income')
	);
	const tenantName = $derived(ready?.summary.tenantName ?? 'your network');

	const currencies = $derived(
		(data?.currencies ?? []).filter((c): c is { code: Currency; scale: number } =>
			(KNOWN as readonly string[]).includes(c.code)
		)
	);
	const scale = $derived(currencies.find((c) => c.code === currency)?.scale ?? 2);
	const amount = $derived(parseAmount(amountText, scale));
	const lines = $derived(data?.allocation?.pockets ?? []);
	const preview = $derived(amount && lines.length ? allocate(amount, scale, lines) : null);
	const shownLines = $derived(
		preview ?? lines.map((l) => ({ ...l, amount: null as string | null }))
	);
	const targetLabel = (t: IncomeTarget) => t.person?.name ?? t.person?.uid ?? 'this member';
	const firstOf = (name: string | null | undefined) => name?.trim().split(/\s+/)[0] ?? null;
	const firstName = $derived(firstOf(target?.person?.name));
	const formatDay = (iso: string) =>
		new Intl.DateTimeFormat(undefined, {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			timeZone: 'UTC'
		}).format(new Date(`${iso}T00:00:00Z`));

	const failureOf = <A,>(exit: Exit.Exit<A, ApiFailure>) =>
		Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) : undefined;

	// ── Loading ──
	async function load() {
		const exit = await Effect.runPromiseExit(getJson(IncomeAppRoutes.targets, IncomeTargets));
		if (Exit.isSuccess(exit)) {
			data = exit.value;
			targets = [...exit.value.items];
			nextCursor = exit.value.nextCursor;
			loadError = null;
			if (!currencies.some((c) => c.code === currency) && currencies[0]) {
				currency = currencies[0].code;
			}
			return;
		}
		const failure = failureOf(exit);
		loadError =
			failure?._tag === 'BackendError' ? incomeMessage(failure) : 'We couldn’t load your members.';
	}

	async function loadMore() {
		if (!nextCursor || loadingMore) return;
		loadingMore = true;
		const exit = await Effect.runPromiseExit(
			getJson(`${IncomeAppRoutes.targets}?cursor=${encodeURIComponent(nextCursor)}`, IncomeTargets)
		);
		loadingMore = false;
		if (Exit.isSuccess(exit)) {
			const seen = new Set(targets.map((t) => t.membershipId));
			targets = [...targets, ...exit.value.items.filter((t) => !seen.has(t.membershipId))];
			nextCursor = exit.value.nextCursor;
		}
	}

	/** Network-wide member search for the picker (owner decision 2026-10-08). */
	async function searchTargets(q: string, cursor: string | null): Promise<IncomeTargets | null> {
		const query = `q=${encodeURIComponent(q)}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`;
		const exit = await Effect.runPromiseExit(
			getJson(`${IncomeAppRoutes.targets}?${query}`, IncomeTargets)
		);
		return Exit.isSuccess(exit) ? exit.value : null;
	}

	$effect(() => {
		const live = liveScope;
		if (!live) return;
		untrack(() => {
			if (!scope) scope = live;
			else if (scope.uid !== live.uid || scope.workspaceId !== live.workspaceId) {
				window.location.reload();
				return;
			}
			if (!data && !loadError) void load();
			// A stored attempt means an earlier dispatch never got an answer.
			const store = browserAttemptStore();
			if (store && scope && phase === 'form' && !attempt) {
				const saved = loadAttempt(store, scope);
				if (saved) {
					attempt = saved;
					commandKey = saved.request.idempotencyKey;
					phase = 'unknown';
				}
			}
		});
	});

	// ── Draft editing ──
	function onTargetChange() {
		// Receipts are bound to the member: they upload again for a new one.
		for (const r of receipts) r.evidenceId = null;
		errors = { ...errors, target: undefined };
	}

	function formatAmountField() {
		const parsed = parseAmount(amountText, scale);
		if (parsed) amountText = `${currencySymbol(currency)}${groupAmount(parsed)}`;
	}

	function formatFeeField() {
		const parsed = parseAmount(feeText, scale);
		if (parsed) feeText = `${currencySymbol(currency)}${groupAmount(parsed)}`;
	}

	function onCurrencyChange() {
		formatAmountField();
		formatFeeField();
	}

	function onFiles(event: Event) {
		const input = event.currentTarget as HTMLInputElement;
		const files = Array.from(input.files ?? []);
		input.value = '';
		let problem: string | null = null;
		for (const file of files) {
			const check = receiptProblem(file, receipts.length);
			if (check) {
				problem = check;
				break;
			}
			receipts = [...receipts, { key: newKey(), file, evidenceId: null, progress: null }];
		}
		errors = { ...errors, receipts: problem ?? undefined };
	}

	function removeReceipt(key: string) {
		receipts = receipts.filter((r) => r.key !== key);
	}

	function draftErrors(): DraftErrors {
		return validateDraft({
			targetMembershipId: target?.membershipId ?? null,
			currency,
			scale,
			amount: amountText,
			source,
			receivedOn,
			notes,
			providerReference,
			feeAmount: feeText,
			feeCurrency: currency,
			receipts: receipts.length,
			today
		});
	}

	function openPost(event: SubmitEvent) {
		event.preventDefault();
		formError = null;
		notice = null;
		const next = draftErrors();
		errors = next;
		if (Object.values(next).some(Boolean)) return;
		dialogError = null;
		pinError = null;
		postOpen = true;
	}

	function buildRequest(evidenceIds: string[]): RecordIncomeInput {
		const fee = parseAmount(feeText, scale);
		const cleanNotes = notes.trim();
		const cleanRef = providerReference.trim();
		return {
			targetMembershipId: target!.membershipId,
			currency,
			amount: amount!,
			source: source.trim(),
			receivedOn,
			...(cleanRef ? { providerReference: cleanRef } : {}),
			...(cleanNotes ? { notes: cleanNotes } : {}),
			...(fee ? { fee: { amount: fee, currency } } : {}),
			evidenceIds,
			idempotencyKey: commandKey
		};
	}

	const isEvidenceRefusal = (failure: ApiFailure | undefined) =>
		failure?._tag === 'BackendError' && failure.code === 'evidence_invalid';

	/** step_up_required / pin_incorrect: ask again in the open sheet. */
	function askPin(failure: ApiFailure | undefined): boolean {
		const problem = pinProblem(failure, 'Enter your PIN to post this income.');
		if (!problem) return false;
		if (problem.kind === 'locked') {
			window.location.assign('/pin/locked');
			return true;
		}
		pinError = problem.message;
		return true;
	}

	// ── Pipeline: receipts, then the income ──
	async function post({ pin }: { pin: string | undefined }) {
		if (!workspaceId || !scope || !target || !amount || busy) return;
		// Freeze what was confirmed; the form is locked while this runs.
		const confirmedTarget = target;
		const confirmed = buildRequest([]);
		busy = true;
		dialogError = null;
		pinError = null;
		let pinLeft = pin;
		for (const receipt of receipts) {
			if (receipt.evidenceId) continue;
			receipt.progress = 0;
			const exit = await Effect.runPromiseExit(
				uploadReceipt(
					{
						file: receipt.file,
						targetMembershipId: confirmed.targetMembershipId,
						idempotencyKey: confirmed.idempotencyKey,
						...(pinLeft ? { pin: pinLeft } : {})
					},
					workspaceId,
					(fraction) => (receipt.progress = fraction)
				)
			);
			receipt.progress = null;
			if (Exit.isSuccess(exit)) {
				receipt.evidenceId = exit.value.evidenceId;
				pinLeft = undefined;
				continue;
			}
			busy = false;
			const failure = failureOf(exit);
			if (askPin(failure)) return;
			if (failure?._tag === 'BackendError' && failure.code === 'rate_limited') {
				// Ten open uploads per attempt key: start a fresh attempt (nothing was
				// dispatched with this key) so the next try uploads under a new one.
				commandKey = newKey();
				for (const r of receipts) r.evidenceId = null;
				dialogError = 'Too many upload tries for this attempt. Try again.';
				return;
			}
			// An upload is not money: any failure here is safe to retry.
			if (fieldOfFailure(failure) === 'receipts' || isEvidenceRefusal(failure)) {
				dialogError = `“${receipt.file.name}” isn’t a readable PDF, JPEG or PNG. Remove it and add it again.`;
			} else if (failure?._tag === 'BackendError') {
				dialogError = incomeMessage(failure);
			} else {
				dialogError = `We couldn’t upload “${receipt.file.name}”. Try again.`;
			}
			return;
		}
		const request: RecordIncomeInput = {
			...confirmed,
			evidenceIds: receipts.map((r) => r.evidenceId!)
		};
		const next: IncomeAttempt = {
			savedAt: Date.now(),
			target: {
				name: confirmedTarget.person?.name ?? null,
				uid: confirmedTarget.person?.uid ?? '',
				officeName: confirmedTarget.officeName
			},
			request
		};
		// No durable copy, no dispatch: an unanswered post must stay recoverable (F-03).
		const store = browserAttemptStore();
		if (!store || !saveAttempt(store, scope, next)) {
			busy = false;
			dialogError =
				'This browser can’t keep a safe copy of the attempt (storage is full or blocked), so nothing was sent. Free up storage or use another browser.';
			return;
		}
		attempt = next;
		await dispatch(request, pinLeft);
	}

	function forgetAttempt() {
		const store = browserAttemptStore();
		if (store && scope) clearAttempt(store, scope);
		attempt = null;
	}

	async function dispatch(request: RecordIncomeInput, pin?: string) {
		if (!workspaceId) return;
		busy = true;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				IncomeAppRoutes.record,
				'POST',
				{ ...request, ...(pin ? { pin } : {}) },
				workspaceId,
				IncomePosted
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) return finish(exit.value);

		const failure = failureOf(exit);
		if (!isDefinitive(failure)) {
			// No answer: it may have posted. Keep the attempt; never a new key (F-03).
			postOpen = false;
			recheckOpen = false;
			phase = 'unknown';
			return;
		}
		if (pinProblem(failure)) {
			// Nothing ran. While the outcome is unknown the attempt stays locked
			// and the PIN sheet re-checks it; otherwise the post sheet asks again.
			if (phase === 'unknown') recheckOpen = true;
			else forgetAttempt();
			askPin(failure);
			return;
		}
		if (failure?._tag === 'BackendError' && failure.code === 'attempt_cancelled') {
			restart('That attempt was cancelled. Nothing was posted.');
			return;
		}
		if (phase === 'unknown') {
			// Session, workspace, permission and input checks run before the backend
			// looks the attempt up, so a refusal here doesn't prove it didn't post.
			// Stay locked: Check again later, or cancel it (the cancel answers with
			// the posted income if there is one).
			recheckOpen = false;
			dialogError = incomeMessage(failure);
			return;
		}
		// The first dispatch of a fresh key was refused: nothing posted.
		const name = attempt?.target.name ?? attempt?.target.uid ?? 'this member';
		forgetAttempt();
		postOpen = false;
		if (isEvidenceRefusal(failure)) {
			// Expired or rejected receipts: upload them again under a fresh key.
			commandKey = newKey();
			for (const r of receipts) r.evidenceId = null;
		}
		if (isFormRefusal(failure)) {
			const field = fieldOfFailure(failure);
			if (field) errors = { ...errors, [field]: incomeMessage(failure) };
			formError = incomeMessage(failure);
			return;
		}
		// J05: a refusal about the member, the network or the setup.
		refusal = { lead: refusalLead(failure, name), aboutTarget: isTargetRefusal(failure) };
		phase = 'refused';
	}

	function finish(posted: IncomePosted) {
		resultFor =
			firstOf(attempt?.target.name) ??
			attempt?.target.uid ??
			(target ? (firstOf(target.person?.name) ?? targetLabel(target)) : '');
		forgetAttempt();
		result = posted;
		phase = 'done';
		postOpen = false;
		recheckOpen = false;
		cancelOpen = false;
		commandKey = newKey();
	}

	/** Back to an editable form after a cancelled unknown attempt. */
	function restart(message: string) {
		const request = attempt?.request;
		forgetAttempt();
		commandKey = newKey();
		receipts = [];
		if (request) restoreDraft(request);
		phase = 'form';
		postOpen = false;
		recheckOpen = false;
		cancelOpen = false;
		notice = message;
	}

	function restoreDraft(request: RecordIncomeInput) {
		target = targets.find((t) => t.membershipId === request.targetMembershipId) ?? target;
		currency = request.currency;
		amountText = `${currencySymbol(request.currency)}${groupAmount(request.amount)}`;
		source = request.source;
		receivedOn = request.receivedOn;
		notes = request.notes ?? '';
		providerReference = request.providerReference ?? '';
		feeText = request.fee
			? `${currencySymbol(request.fee.currency)}${groupAmount(request.fee.amount)}`
			: '';
	}

	// ── J05 actions ──
	function backToForm() {
		refusal = null;
		phase = 'form';
	}

	async function chooseAnother() {
		refusal = null;
		target = null;
		onTargetChange();
		phase = 'form';
		// The picker mounts with the form; open it once it is there.
		await tick();
		picker?.openPicker();
	}

	// ── J04: unknown outcome ──
	async function checkAgain(pin?: string) {
		if (!attempt) return;
		dialogError = null;
		pinError = null;
		if (!pin) {
			if (busy) return;
			busy = true;
			// Shared F-03 lookup first (Blueprint 08): a cancelled attempt needs no
			// replay; committed or not found, the same key goes again below.
			const key = attempt.request.idempotencyKey;
			const exit = await Effect.runPromiseExit(
				getJson(
					`/api/commands/outcome?${new URLSearchParams({ key, command: 'record_income' })}`,
					CommandOutcome
				)
			);
			busy = false;
			if (Exit.isSuccess(exit) && exit.value.status === 'cancelled') {
				restart('That attempt was cancelled. Nothing was posted.');
				return;
			}
		}
		await dispatch(attempt.request, pin);
	}

	async function cancelAttempt({ reason }: { reason: string }) {
		if (!attempt || !workspaceId || busy) return;
		busy = true;
		dialogError = null;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				IncomeAppRoutes.cancel,
				'POST',
				{
					targetMembershipId: attempt.request.targetMembershipId,
					reason,
					idempotencyKey: attempt.request.idempotencyKey
				},
				workspaceId,
				CancelIncomeResult
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			const value = exit.value;
			if (value.status === 'posted') return finish(value);
			restart('Attempt cancelled. Nothing was posted. Add the receipts again to record it.');
			return;
		}
		const failure = failureOf(exit);
		dialogError =
			failure?._tag === 'BackendError'
				? incomeMessage(failure)
				: 'We couldn’t reach Wallet. The attempt is unchanged. Try again.';
	}

	function recordAnother() {
		result = null;
		target = null;
		amountText = '';
		source = '';
		receivedOn = today;
		notes = '';
		providerReference = '';
		feeText = '';
		receipts = [];
		errors = {};
		formError = null;
		notice = null;
		commandKey = newKey();
		phase = 'form';
	}

	const pending = $derived(attempt?.request ?? null);
	const confirmRows = $derived(
		target
			? [
					{
						label: 'To',
						value: target.person
							? `${targetLabel(target)} · ${target.person.uid}`
							: targetLabel(target)
					},
					{ label: 'Source', value: `${source.trim()} · ${formatDay(receivedOn)}` },
					{
						label: 'Receipts',
						value: `${receipts.length} ${receipts.length === 1 ? 'file' : 'files'}`
					}
				]
			: []
	);
</script>

<svelte:head><title>Record income · Elivate Wallet</title></svelte:head>

{#snippet bar()}
	<header class="navbar">
		<a class="close" href="/app" aria-label="Close"
			><X size={22} strokeWidth={2} aria-hidden="true" /></a
		>
		<h1>Record income</h1>
		<span class="spacer" aria-hidden="true"></span>
	</header>
{/snippet}

{#snippet bars(variant: 'desktop' | 'mobile')}
	<div class="bar" class:bar-mobile={variant === 'mobile'} aria-hidden="true">
		{#each lines as line, i (line.pocketId)}
			{#if line.basisPoints > 0}<span
					style:flex-grow={line.basisPoints}
					style:background={pocketColor(i)}
				></span>{/if}
		{/each}
	</div>
{/snippet}

<input
	bind:this={fileInput}
	class="visually-hidden"
	type="file"
	accept="application/pdf,image/jpeg,image/png"
	multiple
	tabindex="-1"
	aria-hidden="true"
	onchange={onFiles}
/>

{#if phase === 'done' && result}
	<Outcome
		pose="income-posted"
		title="Income posted"
		lead={`${formatMoney(result.amount, result.currency)} is in ${resultFor || 'the member'}’s pockets now.`}
		footnote={result.reference}
	>
		{#snippet actions()}
			<a class="out-ghost" href={activityHref}>View in activity</a>
			<button type="button" class="out-primary" onclick={recordAnother}>Record another</button>
		{/snippet}
	</Outcome>
{:else if phase === 'unknown' && pending && attempt}
	<Outcome
		pose="income-checking"
		title="Checking what happened"
		lead={`We’re confirming the ${formatMoney(pending.amount, pending.currency)} income for ${firstOf(attempt.target.name) ?? attempt.target.uid}. Don’t record it again.`}
		footnote={`Sent ${formatSent(attempt.savedAt)}`}
	>
		{#snippet alert()}
			{#if dialogError && !cancelOpen && !recheckOpen}<FormAlert message={dialogError} />{/if}
		{/snippet}
		{#snippet actions()}
			<button
				type="button"
				class="out-ghost"
				disabled={busy || !shell.canAct}
				onclick={() => {
					dialogError = null;
					cancelOpen = true;
				}}>Cancel this attempt</button
			>
			<button
				type="button"
				class="out-primary"
				disabled={busy || !shell.canAct}
				aria-busy={busy}
				onclick={() => checkAgain()}>Check again</button
			>
		{/snippet}
	</Outcome>
{:else if phase === 'refused' && refusal}
	<Outcome pose="income-refused" title="Couldn’t record this income" lead={refusal.lead}>
		{#snippet actions()}
			{#if refusal?.aboutTarget}
				<button type="button" class="out-ghost" onclick={backToForm}>Back to the form</button>
				<button type="button" class="out-primary" onclick={chooseAnother}
					>Choose another member</button
				>
			{:else}
				<button type="button" class="out-primary" onclick={backToForm}>Back to the form</button>
			{/if}
		{/snippet}
	</Outcome>
{:else if !data && !loadError}
	{@render bar()}
	<div class="skeleton" aria-hidden="true"></div>
	<p class="visually-hidden" role="status">Loading your members</p>
{:else if loadError || !data}
	{@render bar()}
	<section class="panel">
		<h2 class="panel-title">We couldn’t load your members</h2>
		<p class="panel-lead">{loadError}</p>
		<div class="panel-actions">
			<button
				type="button"
				class="primary"
				onclick={() => {
					loadError = null;
					void load();
				}}>Try again</button
			>
		</div>
	</section>
{:else if !allowed && targets.length === 0}
	{@render bar()}
	<section class="panel">
		<h2 class="panel-title">You can’t record income here</h2>
		<p class="panel-lead">Recording income is for leaders with that permission in this network.</p>
	</section>
{:else if !data.allocation}
	{@render bar()}
	<section class="panel">
		<h2 class="panel-title">Your network has no split yet</h2>
		<p class="panel-lead">
			Income is split into pockets the moment it’s recorded. Ask the President Team to set the split
			first.
		</p>
	</section>
{:else if targets.length === 0}
	{@render bar()}
	<section class="panel">
		<h2 class="panel-title">No one to record income for yet</h2>
		<p class="panel-lead">Members you lead show up here once they’ve joined.</p>
	</section>
{:else}
	{@render bar()}
	<form class="body" onsubmit={openPost} novalidate>
		<fieldset class="lock" disabled={busy}>
			<div class="form-card">
				{#if notice}<p class="notice" role="status">{notice}</p>{/if}
				{#if formError}<FormAlert message={formError} />{/if}

				<MemberPicker
					bind:this={picker}
					{targets}
					bind:selected={target}
					hasMore={!!nextCursor}
					{loadingMore}
					error={errors.target}
					onLoadMore={loadMore}
					onChange={onTargetChange}
					search={searchTargets}
				/>

				<div class="money">
					<div class="currency-wrap">
						<label class="label" for="income-currency">Currency</label>
						<select
							id="income-currency"
							class="currency"
							bind:value={currency}
							onchange={onCurrencyChange}
						>
							{#each currencies as option (option.code)}
								<option value={option.code}>{option.code}</option>
							{/each}
						</select>
					</div>
					<div class="amount-wrap">
						<label class="label amount-label" for="income-amount">Amount received</label>
						<input
							id="income-amount"
							class="amount"
							inputmode="decimal"
							autocomplete="off"
							placeholder={`${currencySymbol(currency)}0.00`}
							bind:value={amountText}
							onblur={formatAmountField}
							aria-invalid={errors.amount ? 'true' : undefined}
							aria-describedby={errors.amount ? 'amount-error' : undefined}
						/>
					</div>
				</div>
				{#if errors.amount}<p class="error" id="amount-error">{errors.amount}</p>{/if}

				<div class="pair">
					<div class="box" class:bad={!!errors.source}>
						<label class="label" for="income-source">Source</label>
						<input
							id="income-source"
							class="input"
							maxlength="100"
							autocomplete="off"
							placeholder="Where it came from"
							bind:value={source}
							aria-invalid={errors.source ? 'true' : undefined}
							aria-describedby={errors.source ? 'source-error' : undefined}
						/>
					</div>
					<div class="box" class:bad={!!errors.receivedOn}>
						<label class="label" for="income-date">Date received</label>
						<input
							id="income-date"
							class="input"
							type="date"
							max={today}
							bind:value={receivedOn}
							aria-invalid={errors.receivedOn ? 'true' : undefined}
							aria-describedby={errors.receivedOn ? 'date-error' : undefined}
						/>
					</div>
				</div>
				{#if errors.source}<p class="error" id="source-error">{errors.source}</p>{/if}
				{#if errors.receivedOn}<p class="error" id="date-error">{errors.receivedOn}</p>{/if}

				<div class="pair">
					<div class="box" class:bad={!!errors.providerReference}>
						<label class="label" for="income-reference"
							><span class="wide">Provider reference (optional)</span><span class="narrow"
								>Provider ref (optional)</span
							></label
						>
						<input
							id="income-reference"
							class="input"
							maxlength="100"
							autocomplete="off"
							bind:value={providerReference}
						/>
					</div>
					<div class="box" class:bad={!!errors.fee}>
						<label class="label" for="income-fee">Fee (optional)</label>
						<input
							id="income-fee"
							class="input"
							inputmode="decimal"
							autocomplete="off"
							bind:value={feeText}
							onblur={formatFeeField}
							aria-describedby="fee-help"
						/>
					</div>
				</div>
				<p class="visually-hidden" id="fee-help">Recorded only. It isn’t taken off the amount.</p>
				{#if errors.providerReference}<p class="error">{errors.providerReference}</p>{/if}
				{#if errors.fee}<p class="error">{errors.fee}</p>{/if}

				<div class="group">
					<div class="group-head">
						<span class="label" id="receipt-label">Receipts</span>
						<span class="hint"
							><span class="wide">1 to 5 files · PDF, JPG or PNG</span><span class="narrow"
								>1 to 5 files</span
							></span
						>
					</div>
					{#each receipts as receipt (receipt.key)}
						<div
							class="receipt"
							class:uploaded={!!receipt.evidenceId}
							class:uploading={receipt.progress !== null}
						>
							<span class="receipt-icon" aria-hidden="true"
								><FileText size={20} strokeWidth={1.8} /></span
							>
							<span class="receipt-text">
								<span class="receipt-name">{receipt.file.name}</span>
								<span class="receipt-state" aria-live="polite"
									>{receipt.progress !== null
										? `Uploading · ${Math.round(receipt.progress * 100)}%`
										: `${receipt.evidenceId ? 'Uploaded' : 'Ready to upload'} · ${formatSize(receipt.file.size)}`}</span
								>
							</span>
							<button
								type="button"
								class="receipt-action"
								onclick={() => removeReceipt(receipt.key)}
								aria-label={`Remove ${receipt.file.name}`}>Remove</button
							>
						</div>
					{/each}
					{#if receipts.length < RECEIPT_MAX_FILES}
						<button
							type="button"
							class="add-receipt"
							aria-describedby={errors.receipts ? 'receipt-error' : undefined}
							onclick={() => fileInput?.click()}
						>
							<Plus size={16} strokeWidth={2} aria-hidden="true" />
							{receipts.length === 0 ? 'Add a receipt' : 'Add another receipt'}
						</button>
					{/if}
					{#if errors.receipts}<p class="error" id="receipt-error">{errors.receipts}</p>{/if}
				</div>

				<div class="group">
					<label class="label" for="income-notes">Notes (optional)</label>
					<textarea
						id="income-notes"
						class="notes"
						maxlength="1000"
						placeholder="Anything they should know?"
						bind:value={notes}></textarea>
					{#if errors.notes}<p class="error">{errors.notes}</p>{/if}
				</div>

				<!-- Mobile split preview (J01 mobile). -->
				<div class="split-mobile">
					<div class="split-head">
						<span class="eyebrow">Split preview</span>
						<span class="split-ratio"
							>{lines.map((l) => shortPercent(l.basisPoints)).join(' / ')}</span
						>
					</div>
					{@render bars('mobile')}
					<ul class="split-wrap">
						{#each shownLines as line (line.pocketId)}
							<li>
								{shortPocket(line.name)}
								{line.amount !== null ? formatMoney(line.amount, currency) : '—'}
							</li>
						{/each}
					</ul>
				</div>

				<button
					type="submit"
					class="post post-mobile"
					disabled={!shell.canAct || shell.paused('income')}>Review and post</button
				>
			</div>

			<!-- Desktop preview (J01 desktop). -->
			<aside class="preview" aria-label="What they will receive">
				<div class="preview-head">
					<span class="eyebrow"
						>{firstName ? `${firstName} will receive` : 'They will receive'}</span
					>
					<span class="preview-amount">+{formatMoney(amount ?? '0.00', currency)}</span>
					<span class="preview-sub"
						>Split by {tenantName}’s policy · version {data.allocation.version}</span
					>
				</div>
				<div class="preview-lines">
					{@render bars('desktop')}
					{#each shownLines as line, i (line.pocketId)}
						<div class="line">
							<span class="line-name"
								><span class="dot" style:background={pocketColor(i)} aria-hidden="true"
								></span>{line.name} · {shortPercent(line.basisPoints)}%</span
							>
							<span class="line-amount"
								>{line.amount !== null ? formatMoney(line.amount, currency) : '—'}</span
							>
						</div>
					{/each}
				</div>
				<div class="preview-foot">
					<button type="submit" class="post" disabled={!shell.canAct || shell.paused('income')}
						>Review and post</button
					>
				</div>
				<div class="stage" aria-hidden="true">
					<div class="shade"></div>
					<div class="stage-grain"></div>
					<RootImage pose="income-abacus" class="stage-root" sizes="176px" />
				</div>
			</aside>
		</fieldset>
	</form>
{/if}

<IncomeConfirm
	bind:open={postOpen}
	title={amount ? `Post ${formatMoney(amount, currency)}?` : 'Post this income?'}
	lead={`It lands in ${firstName ?? 'their'}${firstName ? '’s' : ''} pockets straight away`}
	rows={confirmRows}
	{busy}
	error={dialogError}
	{pinError}
	onConfirm={post}
/>

<ConfirmDialog
	bind:open={recheckOpen}
	title="Check this income again"
	summary="Enter your PIN to check whether it posted. It can never post twice."
	confirmLabel="Check again"
	needsReason={false}
	{busy}
	error={dialogError}
	{pinError}
	onConfirm={({ pin }) => checkAgain(pin)}
/>

<ConfirmDialog
	bind:open={cancelOpen}
	title="Cancel this attempt?"
	summary="If it already posted, you’ll see the posted income instead. Nothing is deleted."
	confirmLabel="Cancel attempt"
	cancelLabel="Keep it"
	reasonLabel="Why are you cancelling it?"
	needsPin={false}
	tone="danger"
	{busy}
	error={dialogError}
	onConfirm={cancelAttempt}
/>

<style>
	/* ── Mobile first (J01 mobile) ───────────────────────────────── */

	.navbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: calc(4px + env(safe-area-inset-top)) 12px 8px;
	}

	.close,
	.spacer {
		display: flex;
		align-items: center;
		justify-content: center;
		width: var(--hit-min);
		height: var(--hit-min);
		color: var(--color-text);
	}

	h1 {
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.body {
		display: flex;
		flex-direction: column;
		padding: 8px 20px calc(24px + env(safe-area-inset-bottom));
	}

	.lock {
		display: contents;
		min-width: 0;
		margin: 0;
		padding: 0;
		border: 0;
	}

	.form-card {
		display: flex;
		flex-direction: column;
		gap: 16px;
		min-width: 0;
	}

	.label {
		color: var(--shell-strong, var(--color-text));
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: 16px;
	}

	.wide {
		display: none;
	}

	.hint {
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
	}

	.error {
		margin-top: -8px;
		color: var(--color-danger);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.notice {
		padding: 10px 14px;
		border-radius: var(--radius-12);
		background: color-mix(in oklab, var(--color-info) 14%, transparent);
		font-size: var(--text-14);
	}

	/* Amount card: currency chip, big amount, label below. */
	.money {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 6px;
		padding: 18px 16px;
		border: 1px solid #ffffff14;
		border-radius: 18px;
		background: var(--color-surface);
	}

	:global([data-theme='light']) .money,
	:global([data-theme='light']) .split-mobile,
	:global([data-theme='light']) .preview,
	:global([data-theme='light']) .form-card {
		border-color: var(--color-border);
	}

	.currency-wrap .label {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip-path: inset(50%);
		white-space: nowrap;
	}

	.currency {
		appearance: none;
		padding: 3px 26px 3px 10px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--color-raised)
			url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24'%3E%3Cpath d='m6 9 6 6 6-6' fill='none' stroke='%23A9B0B3' stroke-width='2' stroke-linecap='round'/%3E%3C/svg%3E")
			no-repeat right 10px center;
		color: var(--shell-strong, var(--color-text));
		font: inherit;
		font-size: 12px;
		line-height: 16px;
		cursor: pointer;
	}

	.amount-wrap {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 6px;
		width: 100%;
	}

	.amount-label {
		order: 2;
		color: var(--color-muted);
		font-size: 12px;
		font-weight: var(--font-weight-regular);
	}

	.amount {
		width: 100%;
		min-width: 0;
		padding: 0;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 40px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.03em;
		line-height: 48px;
		text-align: center;
	}

	.amount::placeholder {
		color: var(--shell-faint, var(--color-muted));
	}

	.amount:focus {
		outline: none;
	}

	.money:focus-within {
		border-color: var(--color-accent);
	}

	.pair {
		display: flex;
		gap: 10px;
	}

	.box {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 4px;
		min-width: 0;
		padding: 12px 14px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
	}

	.box:focus-within {
		border-color: var(--color-accent);
	}

	.box.bad {
		border-color: var(--color-danger);
	}

	.box .label {
		color: var(--color-muted);
		font-size: 11px;
		font-weight: var(--font-weight-regular);
		line-height: 14px;
	}

	.box .input {
		width: 100%;
		min-width: 0;
		padding: 0;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 14px;
		line-height: 18px;
	}

	.box .input:focus {
		outline: none;
	}

	.input::placeholder,
	.notes::placeholder {
		color: var(--shell-faint, var(--color-muted));
	}

	.group {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.group-head {
		display: flex;
		justify-content: space-between;
	}

	.receipt {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 14px 16px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
	}

	.receipt.uploaded,
	.receipt.uploading {
		border-color: #43c48b55;
		background: #1d2e2633;
	}

	.receipt.uploading {
		border-style: dashed;
	}

	.receipt-icon {
		display: flex;
		flex-shrink: 0;
		align-items: center;
		justify-content: center;
		width: 40px;
		height: 40px;
		border-radius: 10px;
		background: var(--color-raised);
		color: var(--color-muted);
	}

	.receipt.uploaded .receipt-icon,
	.receipt.uploading .receipt-icon {
		background: #1d2e26;
		color: var(--color-success);
	}

	.receipt-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.receipt-name {
		overflow: hidden;
		color: var(--color-text);
		font-size: 14px;
		line-height: 18px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.receipt-state {
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
	}

	.receipt.uploaded .receipt-state {
		color: var(--color-success);
	}

	.receipt-action {
		min-height: var(--hit-min);
		padding: 0 4px;
		border: 0;
		background: none;
		color: var(--color-muted);
		font: inherit;
		font-size: 13px;
		line-height: 16px;
		cursor: pointer;
	}

	.add-receipt {
		display: flex;
		align-self: flex-start;
		align-items: center;
		gap: 8px;
		height: 40px;
		padding: 0;
		border: 0;
		background: none;
		color: var(--color-accent-text);
		font: inherit;
		font-size: 14px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		cursor: pointer;
	}

	.notes {
		height: 72px;
		padding: 14px 16px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 14px;
		line-height: 18px;
		resize: vertical;
	}

	.notes:focus {
		outline: none;
		border-color: var(--color-accent);
	}

	.split-mobile {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 16px;
		border: 1px solid #ffffff14;
		border-radius: 16px;
		background: var(--color-surface);
	}

	.split-head {
		display: flex;
		justify-content: space-between;
		gap: 12px;
	}

	.eyebrow {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 12px;
		letter-spacing: 0.08em;
		line-height: 16px;
		text-transform: uppercase;
	}

	.split-ratio {
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
	}

	.bar {
		display: flex;
		flex-shrink: 0;
		gap: 3px;
		height: 8px;
	}

	.bar span {
		flex-basis: 0;
		border-radius: var(--radius-pill);
	}

	.split-wrap {
		display: flex;
		flex-wrap: wrap;
		gap: 8px 16px;
		list-style: none;
	}

	.split-wrap li {
		color: var(--shell-strong, var(--color-text));
		font-size: 12px;
		line-height: 16px;
	}

	.post {
		height: 54px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--button-primary-bg);
		box-shadow:
			#ffffff59 0px 1px 0px inset,
			var(--button-primary-glow) 0px 10px 28px -10px;
		color: var(--button-primary-ink);
		font: inherit;
		font-size: 16px;
		font-weight: var(--font-weight-semibold);
		line-height: 20px;
		cursor: pointer;
	}

	.post:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	.preview {
		display: none;
	}

	/* ── Empty and error states (not drawn in Paper) ─────────────── */

	.panel {
		display: flex;
		flex-direction: column;
		gap: 12px;
		margin: 8px 20px 24px;
		padding: 24px;
		border: 1px solid var(--color-border);
		border-radius: 20px;
		background: var(--color-surface);
	}

	.panel-title {
		font-size: var(--text-24);
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.02em;
		line-height: var(--leading-32);
	}

	.panel-lead {
		color: var(--color-muted);
		font-size: 15px;
		line-height: 22px;
	}

	.panel-actions {
		display: flex;
		gap: 12px;
		padding-top: 4px;
	}

	.primary {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		min-height: 48px;
		padding: 0 22px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--button-primary-bg);
		box-shadow: var(--auth-button-shadow);
		color: var(--button-primary-ink);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.skeleton {
		height: 520px;
		margin: 8px 20px;
		border-radius: 20px;
		background: var(--color-surface);
	}

	/* ── Desktop (J01 desktop) ───────────────────────────────────── */

	@media (min-width: 1024px) {
		.navbar {
			display: none;
		}

		.wide {
			display: inline;
		}

		.narrow {
			display: none;
		}

		.body {
			gap: 24px;
			padding: 0;
		}

		.form-card {
			gap: 24px;
			padding: 32px;
			border: 1px solid #ffffff14;
			border-radius: 20px;
			background: var(--color-surface);
		}

		.error {
			margin-top: -16px;
		}

		.money {
			flex-direction: row;
			align-items: stretch;
			gap: 12px;
			padding: 0;
			border: 0;
			border-radius: 0;
			background: none;
		}

		.money:focus-within {
			border-color: transparent;
		}

		.currency-wrap {
			display: flex;
			flex-shrink: 0;
			flex-direction: column;
			gap: 10px;
			width: 140px;
		}

		.currency-wrap .label {
			position: static;
			width: auto;
			height: auto;
			overflow: visible;
			clip-path: none;
		}

		.currency {
			height: 56px;
			padding: 0 40px 0 16px;
			border: 1px solid var(--color-border);
			border-radius: 14px;
			background-color: transparent;
			background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' viewBox='0 0 24 24'%3E%3Cpath d='m6 9 6 6 6-6' fill='none' stroke='%23A9B0B3' stroke-width='2' stroke-linecap='round'/%3E%3C/svg%3E");
			background-position: right 16px center;
			color: var(--color-text);
			font-size: 15px;
			line-height: 18px;
		}

		.amount-wrap {
			flex: 1;
			align-items: stretch;
			gap: 10px;
		}

		.amount-label {
			order: 0;
			color: var(--shell-strong, var(--color-text));
			font-size: 13px;
			font-weight: var(--font-weight-medium);
		}

		.amount {
			height: 56px;
			padding: 0 16px;
			border: 1px solid var(--color-border);
			border-radius: 14px;
			background: var(--color-canvas);
			font-size: 22px;
			letter-spacing: normal;
			line-height: 28px;
			text-align: left;
		}

		.amount:focus {
			border: 1.5px solid var(--color-accent);
		}

		.amount[aria-invalid='true'] {
			border-color: var(--color-danger);
		}

		.pair {
			gap: 12px;
		}

		.box {
			gap: 10px;
			padding: 0;
			border: 0;
			border-radius: 0;
		}

		.box .label {
			color: var(--shell-strong, var(--color-text));
			font-size: 13px;
			font-weight: var(--font-weight-medium);
			line-height: 16px;
		}

		.box .input {
			height: 56px;
			padding: 0 16px;
			border: 1px solid var(--color-border);
			border-radius: 14px;
			font-size: 15px;
		}

		.box .input:focus {
			border-color: var(--color-accent);
		}

		.box.bad .input {
			border-color: var(--color-danger);
		}

		.split-mobile,
		.post-mobile {
			display: none;
		}

		.preview {
			display: flex;
			flex-direction: column;
			overflow: clip;
			border: 1px solid #ffffff14;
			border-radius: 20px;
			background: var(--color-surface);
		}

		.preview-head {
			display: flex;
			flex-direction: column;
			gap: 6px;
			padding: 24px 24px 20px;
			border-bottom: 1px solid #ffffff0f;
		}

		.preview-amount {
			color: var(--color-success);
			font-size: 34px;
			font-weight: var(--font-weight-semibold);
			letter-spacing: -0.02em;
			line-height: 42px;
			overflow-wrap: anywhere;
		}

		.preview-sub {
			color: var(--color-muted);
			font-size: 12px;
			line-height: 16px;
		}

		.preview-lines {
			display: flex;
			flex-direction: column;
			gap: 12px;
			padding: 20px 24px;
			border-bottom: 1px solid #ffffff0f;
		}

		.line {
			display: flex;
			justify-content: space-between;
			gap: 12px;
		}

		.line-name {
			display: flex;
			align-items: center;
			gap: 8px;
			color: var(--shell-strong, var(--color-text));
			font-size: 13px;
			line-height: 16px;
		}

		.line-amount {
			color: var(--color-text);
			font-size: 13px;
			line-height: 16px;
			font-variant-numeric: tabular-nums;
		}

		.dot {
			flex-shrink: 0;
			width: 8px;
			height: 8px;
			border-radius: var(--radius-pill);
		}

		.preview-foot {
			display: flex;
			flex-direction: column;
			gap: 14px;
			padding: 20px 24px 24px;
		}

		.post {
			height: 50px;
			font-size: 15px;
			line-height: 18px;
		}

		.stage {
			position: relative;
			display: flex;
			flex-shrink: 0;
			justify-content: center;
			height: 220px;
			overflow: clip;
			background: var(--color-surface) url('/root/stage.webp') 50% / cover;
		}

		.shade {
			position: absolute;
			inset: 0;
			background: linear-gradient(
				in oklab 180deg,
				oklab(21.5% -0.004 -0.003 / 0%) 30%,
				oklab(21.5% -0.004 -0.003 / 85%) 100%
			);
		}

		.stage-grain {
			position: absolute;
			inset: 0;
			/* Blueprint 20 B8: the 128 px tile, four times, fills the same centred 256 px square. */
			background:
				url('/auth-bg/grain-128.webp') calc(50% - 64px) calc(50% - 64px) / 128px 128px no-repeat,
				url('/auth-bg/grain-128.webp') calc(50% + 64px) calc(50% - 64px) / 128px 128px no-repeat,
				url('/auth-bg/grain-128.webp') calc(50% - 64px) calc(50% + 64px) / 128px 128px no-repeat,
				url('/auth-bg/grain-128.webp') calc(50% + 64px) calc(50% + 64px) / 128px 128px no-repeat;
			mix-blend-mode: overlay;
			opacity: 0.25;
		}

		.stage :global(.stage-root) {
			position: absolute;
			bottom: -10px;
			width: 176px;
			height: 236px;
		}

		.panel {
			max-width: 640px;
			margin: 0;
			padding: 32px;
		}

		.skeleton {
			margin: 0;
		}
	}

	@media (min-width: 1200px) {
		.body {
			flex-direction: row;
			align-items: start;
		}

		.form-card {
			flex: 1;
		}

		.preview {
			flex-shrink: 0;
			width: 380px;
		}
	}
</style>
