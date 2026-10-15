<!--
	Request a withdrawal (W-09), Paper "App — Screens v1" M06 (amount) → M07
	(review + PIN) → M08 (request sent); mobile M09–M11. Unknown outcome (B16 /
	B16d) is the shared F-03 recovery screen bound to the same attempt.

	NGN only: pick a pocket with money available, an amount up to what it has
	available (requests already open are reserved), and a usable payout
	account (verified, not cooling off, name not mismatched), and what it is
	for (Blueprint 40, Paper WR01: a required note of 3–500 characters).
	Submitting needs a fresh PIN and reserves the amount at once; the posted
	balance changes only once the payout receipt is verified.
-->
<script lang="ts">
	import { enterMovesOn } from '#lib/ui/enter-moves-on.js';
	import { getContext, untrack } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import { MediaQuery } from 'svelte/reactivity';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import Delete from '@lucide/svelte/icons/delete';
	import Landmark from '@lucide/svelte/icons/landmark';
	import X from '@lucide/svelte/icons/x';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';
	import {
		Withdrawal,
		WithdrawalAppRoutes,
		WithdrawalSources,
		type WithdrawalSource
	} from '#lib/contract/withdrawals.js';
	import { getJson } from '#lib/client/api.js';
	import { CommandAttempt } from '#lib/client/command-attempt.svelte.js';
	import { cachedPage, type PageLoaded } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { groupAmount, parseAmount } from '#lib/income.js';
	import { formatMoney, isZero, sumMoney } from '#lib/money.js';
	import { accountTitle } from '#lib/payout.js';
	import { pinProblem } from '#lib/payout.js';
	import { moveMessage, withinRequested } from '#lib/withdrawals.js';
	import ConfirmDialog from '#lib/ui/app/ConfirmDialog.svelte';
	import OutcomeUnknown from '#lib/ui/app/OutcomeUnknown.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import '#lib/ui/money/money.css';
	import NoAccess from '#lib/ui/app/NoAccess.svelte';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';

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

	let sourceId = $state<string | null>(null);
	let amountText = $state('');
	let payoutAccountId = $state<string | null>(null);
	let amountError = $state<string | null>(null);
	let formError = $state<string | null>(null);
	let step = $state<'amount' | 'review'>('amount');
	let pinOpen = $state(false);
	let pinError = $state<string | null>(null);
	let dialogError = $state<string | null>(null);
	let chooseAccount = $state(false);
	// Blueprint 40: kept in page state, so going back to the amount keeps it.
	let reason = $state('');
	let reasonError = $state<string | null>(null);
	let reasonField = $state<HTMLTextAreaElement | null>(null);

	const attempt = new CommandAttempt({
		command: 'request_withdrawal',
		path: WithdrawalAppRoutes.mine,
		method: 'POST',
		schema: Withdrawal,
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
	const result = $derived(attempt.state.kind === 'done' ? attempt.state.result : null);

	const DENIED = 'Withdrawals aren’t open to you in this network.';
	async function readSources(): Promise<PageLoaded<WithdrawalSources>> {
		const exit = await Effect.runPromiseExit(
			getJson(WithdrawalAppRoutes.sources, WithdrawalSources)
		);
		if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		const isBackend = failure?._tag === 'BackendError';
		const denied = isBackend && failure.code === 'authorization_denied';
		return {
			ok: false,
			text: denied ? DENIED : 'We couldn’t load your pockets.',
			status: isBackend ? failure.status : null
		};
	}

	// Blueprint 23: the pockets and payout accounts open from cache, then
	// refresh (masked account numbers only). The request itself always goes to
	// the server, and "Continue to review" waits for the fresh copy.
	const view = cachedPage(shell, {
		kind: 'withdrawals',
		part: () => 'sources',
		load: readSources
	});
	const data = $derived(view.data);
	const denied = $derived(view.error === DENIED);
	const loadError = $derived(view.data ? null : view.error);

	// Defaults once data is shown; kept by id across refreshes (a choice that
	// is gone from the fresh copy falls back to the default).
	$effect(() => {
		const value = view.data;
		if (!value) return;
		untrack(() => {
			if (!value.sources.some((s) => s.accountId === sourceId)) {
				sourceId = value.sources.find((s) => !isZero(s.available))?.accountId ?? null;
			}
			const usable = value.payoutAccounts.filter((a) => a.usable);
			if (!value.payoutAccounts.some((a) => a.payoutAccountId === payoutAccountId)) {
				payoutAccountId = (usable.find((a) => a.isPrimary) ?? usable[0])?.payoutAccountId ?? null;
			}
		});
	});

	const source = $derived<WithdrawalSource | null>(
		data?.sources.find((s) => s.accountId === sourceId) ?? null
	);
	const account = $derived(
		data?.payoutAccounts.find((a) => a.payoutAccountId === payoutAccountId) ?? null
	);
	const amount = $derived(parseAmount(amountText, 2));
	const multiOffice = $derived(new Set(data?.sources.map((s) => s.membershipId)).size > 1);

	function validate(): boolean {
		amountError = null;
		formError = null;
		if (!source) {
			formError = 'Choose a pocket to withdraw from.';
			return false;
		}
		if (!amount) {
			amountError = 'Enter an amount, like 120,000.00.';
			return false;
		}
		if (!withinRequested(amount, null, source.available)) {
			amountError = `You can withdraw up to ${formatMoney(source.available, 'NGN')} from ${source.pocket.name}.`;
			return false;
		}
		if (!account || !account.usable) {
			formError = 'Choose a payout account that can receive withdrawals.';
			return false;
		}
		return true;
	}

	function toReview(event: SubmitEvent) {
		event.preventDefault();
		if (validate()) step = 'review';
	}

	/** The note's problem, if any (same rule as the server: 3–500 characters after trimming). */
	function reasonProblem(text: string): string | null {
		const length = [...text.trim()].length;
		if (length < 3) return 'Say what this withdrawal is for (at least 3 characters).';
		if (length > 500) return 'Keep it to 500 characters.';
		return null;
	}

	function openPin() {
		// The button stays tappable: an invalid note is shown and focused, never silently blocked.
		reasonError = reasonProblem(reason);
		if (reasonError) {
			reasonField?.focus();
			return;
		}
		pinError = null;
		dialogError = null;
		pinOpen = true;
	}

	async function submit({ pin }: { reason: string; pin: string | undefined }) {
		if (!source || !amount || !account || shell.state.kind !== 'ready') return;
		dialogError = null;
		pinError = null;
		const summary = `${formatMoney(amount, 'NGN')} to ${accountTitle(account)}`;
		const state = attempt.awaitingPin
			? await attempt.resend({ ...(pin ? { pin } : {}) })
			: await attempt.send(
					shell.state.view.workspace.membershipId,
					{
						accountId: source.accountId,
						amount,
						payoutAccountId: account.payoutAccountId,
						reason: reason.trim()
					},
					{ ...(pin ? { pin } : {}), summary }
				);
		if (state.kind === 'done') {
			pinOpen = false;
			return;
		}
		if (state.kind !== 'failed') {
			pinOpen = false;
			return;
		}
		const problem = pinProblem(state.failure);
		if (problem?.kind === 'locked') return void window.location.assign('/pin/locked');
		if (problem) return void (pinError = problem.message);
		attempt.reset();
		dialogError = moveMessage(state.failure);
		if (state.failure._tag === 'BackendError' && state.failure.code === 'insufficient_funds') {
			void view.reload();
		}
	}

	// ── Slice 29: the phone flow, Paper M09 (amount) and M10 (review) ──
	const wide = new MediaQuery('(min-width: 1024px)');
	/** The digits typed on the keypad ("120000.5"); the field above shows them grouped. */
	const KEYS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', 'back'] as const;
	function press(key: (typeof KEYS)[number]) {
		amountError = null;
		formError = null;
		const raw = amountText.replace(/[^0-9.]/g, '');
		if (key === 'back') return void (amountText = raw.slice(0, -1));
		if (key === '.') return void (amountText = raw.includes('.') ? raw : `${raw || '0'}.`);
		const [whole = '', cents] = raw.split('.');
		if (cents !== undefined ? cents.length >= 2 : whole.length >= 12) return;
		amountText = raw === '0' ? key : raw + key;
	}
	/** A hardware keyboard works on the keypad too. */
	function keypadKey(event: KeyboardEvent) {
		if (wide.current || step !== 'amount' || pinOpen) return;
		if (event.ctrlKey || event.metaKey || event.altKey) return;
		if ((event.target as HTMLElement).closest('input, textarea, [data-wheel-picker]')) return;
		const key = event.key === 'Backspace' ? 'back' : event.key === ',' ? '.' : event.key;
		if ((KEYS as readonly string[]).includes(key)) {
			event.preventDefault();
			press(key as (typeof KEYS)[number]);
		}
	}
	const shownAmount = $derived.by(() => {
		const raw = amountText.replace(/[^0-9.]/g, '');
		if (!raw) return '₦0';
		const [whole = '0', cents] = raw.split('.');
		const grouped = Number(whole || '0').toLocaleString('en-NG');
		return `₦${grouped}${cents !== undefined ? `.${cents}` : ''}`;
	});

	const reasonLength = $derived([...reason.trim()].length);
	const reservedAfter = $derived(source && amount ? sumMoney([source.reserved, amount]) : null);
	const availableAfter = $derived(
		source && amount ? sumMoney([source.available, `-${amount}`]) : null
	);
</script>

<svelte:head><title>New withdrawal · Elivate Wallet</title></svelte:head>
<svelte:window onkeydown={keypadKey} />

{#snippet navbar(title: string, n: number)}
	<header class="navbar">
		{#if n === 1}
			<a class="nav-icon" href="/app/withdrawals" aria-label="Close"
				><X size={22} strokeWidth={2} aria-hidden="true" /></a
			>
		{:else}
			<button
				type="button"
				class="nav-icon"
				aria-label="Back to amount"
				onclick={() => (step = 'amount')}
				><ChevronLeft size={22} strokeWidth={2} aria-hidden="true" /></button
			>
		{/if}
		<h1 tabindex="-1">{title}</h1>
		<span class="nav-step">{n} / 3</span>
	</header>
{/snippet}

<!-- Blueprint 40, Paper WR01: what the withdrawal is for (required). -->
{#snippet reasonBlock()}
	<div class="reason">
		<div class="reason-head">
			<label class="reason-label" for="wd-reason">What’s this withdrawal for?</label>
			<span class="reason-req">Required</span>
		</div>
		<textarea
			id="wd-reason"
			class="reason-field"
			bind:this={reasonField}
			bind:value={reason}
			rows="2"
			maxlength="600"
			autocomplete="off"
			placeholder="For example, school fees for the second term"
			aria-invalid={reasonError ? 'true' : undefined}
			aria-describedby="wd-reason-hint"
			oninput={() => {
				if (reasonError) reasonError = reasonProblem(reason);
			}}></textarea>
		{#if reasonError}
			<p class="mm-error" id="wd-reason-hint" role="alert">{reasonError}</p>
		{:else}
			<p class="reason-hint" id="wd-reason-hint">
				Your leader sees this when they approve it.{reasonLength > 450
					? ` ${500 - reasonLength} characters left.`
					: ''}
			</p>
		{/if}
	</div>
{/snippet}

{#if recovering}
	<OutcomeUnknown
		{attempt}
		noun="withdrawal"
		backHref="/app/withdrawals"
		backLabel="Back to withdrawals"
	/>
{:else if result}
	<section class="sent">
		<div class="sent-hero">
			<div class="shade" aria-hidden="true"></div>
			<RootImage pose="income-posted" class="sent-root" sizes="190px" eager />
		</div>
		<span class="mm-pill warning">Requested · waiting for approval</span>
		<h1 class="mm-title" tabindex="-1">Request sent</h1>
		<p class="sent-lead">
			{formatMoney(result.amount, 'NGN')} is now reserved in {result.pocket.name}. We’ll notify you
			when it’s approved and again when the payout to {result.destination.bankName ?? 'your bank'} ••
			{result.destination.accountLast4} is verified.
		</p>
		<div class="mm-actions sent-actions">
			<a class="mm-btn" href="/app">Back to Home</a>
			<a class="mm-btn primary" href="/app/withdrawals">Track this withdrawal</a>
		</div>
		<p class="mm-ref">Reference {result.reference}</p>
	</section>
{:else if denied}
	<NoAccess lead={loadError ?? undefined} />
{:else}
	<div class="mm-page" class:phone={!wide.current}>
		{#if !wide.current}
			{@render navbar(step === 'amount' ? 'Withdraw' : 'Review', step === 'amount' ? 1 : 2)}
		{:else}
			<h1 class="mm-title" tabindex="-1">
				{step === 'amount' ? 'Withdraw to your bank' : 'Review your withdrawal'}
			</h1>
			<ol class="mm-stepper">
				<li aria-current={step === 'amount' ? 'step' : undefined}>
					<span class="n">{step === 'amount' ? '1' : '✓'}</span> Amount
				</li>
				<li aria-current={step === 'review' && !pinOpen ? 'step' : undefined}>
					<span class="n">2</span> Review
				</li>
				<li aria-current={pinOpen ? 'step' : undefined}>
					<span class="n">3</span> Confirm with PIN
				</li>
			</ol>
		{/if}

		<CacheNote savedAt={view.savedAt} online={shell.online} failed={view.error !== null} />

		{#if !data && !loadError}
			<div class="mm-skeleton" aria-hidden="true"></div>
		{:else if loadError || !data}
			<p class="mm-empty" role="alert">{loadError}</p>
		{:else if data.sources.length === 0}
			<p class="mm-empty">You don’t have money to withdraw in this network yet.</p>
		{:else}
			<div class="layout">
				{#if step === 'amount' && !wide.current}
					<!-- Paper M09: pocket chip, the amount, the account, a keypad. -->
					<form class="m09" onsubmit={toReview} novalidate>
						<div class="chip-row">
							<WheelPicker
								id="wd-pocket"
								label="From pocket"
								title="Withdraw from"
								class="pocket-chip"
								fit
								triggerText={source ? `From ${source.pocket.name} · NGN` : 'Choose a pocket'}
								options={data.sources.map((s) => ({
									value: s.accountId,
									label: s.pocket.name,
									hint: `${formatMoney(s.available, 'NGN')} available${multiOffice ? ` · ${s.office.name}` : ''}`,
									disabled: isZero(s.available)
								}))}
								value={sourceId}
								onchange={(id) => {
									sourceId = id;
									amountError = null;
									formError = null;
								}}
							/>
						</div>

						<div class="amount-block">
							<p class="big-amount" class:empty={!amount} aria-live="polite">
								<span class="visually-hidden">Amount: </span>{shownAmount}<span
									class="caret"
									aria-hidden="true"
								></span>
							</p>
							{#if amountError}
								<p class="mm-error center" role="alert">{amountError}</p>
							{:else if source}
								<p class="avail">
									{formatMoney(source.available, 'NGN')} available in {source.pocket.name}
								</p>
							{/if}
							{#if source}
								<button
									type="button"
									class="use-max"
									onclick={() => {
										amountText = source.available;
										amountError = null;
									}}>Use max</button
								>
							{/if}
						</div>

						{#if data.payoutAccounts.length === 0}
							<p class="mm-note center">
								Add a bank account first. <a class="mm-link" href="/app/payout-accounts/add"
									>Add payout account</a
								>
							</p>
						{:else}
							<div class="to-card">
								<span class="to-icon" aria-hidden="true"
									><Landmark size={18} strokeWidth={1.8} /></span
								>
								<span class="to-text">
									<span class="to-label">To</span>
									<span class="to-name"
										>{account ? accountTitle(account) : 'Choose an account'}</span
									>
								</span>
								{#if data.payoutAccounts.length > 1}
									<WheelPicker
										id="wd-account"
										label="Payout account"
										title="Send it to"
										class="to-change"
										fit
										triggerText="Change"
										options={data.payoutAccounts.map((a) => ({
											value: a.payoutAccountId,
											label: accountTitle(a),
											hint: a.usable ? a.accountName : 'Can’t receive yet',
											disabled: !a.usable
										}))}
										value={payoutAccountId}
										onchange={(id) => (payoutAccountId = id)}
									/>
								{/if}
							</div>
						{/if}

						{#if formError}<p class="mm-error center" role="alert">{formError}</p>{/if}

						<div class="keypad" role="group" aria-label="Amount keypad">
							{#each KEYS as key (key)}
								<button
									type="button"
									class="key"
									aria-label={key === 'back' ? 'Delete' : key === '.' ? 'Point' : key}
									onclick={() => press(key)}
								>
									{#if key === 'back'}<Delete
											size={26}
											strokeWidth={1.8}
											aria-hidden="true"
										/>{:else}{key}{/if}
								</button>
							{/each}
						</div>

						<button
							type="submit"
							class="continue"
							disabled={!shell.canAct || shell.paused('withdrawals') || view.savedAt !== null}
							>Continue</button
						>
					</form>
				{:else if step === 'amount'}
					<form class="mm-card" onsubmit={toReview} novalidate {@attach enterMovesOn}>
						{#if formError}<p class="mm-error" role="alert">{formError}</p>{/if}
						<div class="mm-field" role="radiogroup" aria-label="From pocket">
							<span class="mm-field-label">From pocket</span>
							<div class="mm-pockets">
								{#each data.sources as s, i (s.accountId)}
									<button
										type="button"
										role="radio"
										class="mm-pocket"
										style={`--dot: ${DOTS[i % DOTS.length]}`}
										aria-checked={sourceId === s.accountId}
										disabled={isZero(s.available)}
										onclick={() => (sourceId = s.accountId)}
									>
										<span class="mm-pocket-name">{s.pocket.name}</span>
										<span class="mm-pocket-sub"
											>{formatMoney(s.available, 'NGN')} available{multiOffice
												? ` · ${s.office.name}`
												: ''}</span
										>
									</button>
								{/each}
							</div>
						</div>

						<div class="mm-field">
							<label class="mm-field-label" for="wd-amount">Amount</label>
							<div class="mm-amount-box">
								<input
									id="wd-amount"
									inputmode="decimal"
									autocomplete="off"
									placeholder="₦0.00"
									aria-invalid={amountError ? 'true' : undefined}
									aria-describedby="wd-amount-hint"
									value={amountText}
									oninput={(e) => {
										amountText = e.currentTarget.value;
										amountError = null;
									}}
									onblur={() => {
										if (amount) amountText = `₦${groupAmount(amount)}`;
									}}
								/>
								{#if source}
									<button
										type="button"
										class="mm-chip-btn"
										onclick={() => (amountText = `₦${groupAmount(source.available)}`)}
										>Use max</button
									>
								{/if}
							</div>
							{#if amountError}
								<p class="mm-error" id="wd-amount-hint" role="alert">{amountError}</p>
							{:else if source}
								<p class="mm-note" id="wd-amount-hint">
									You can withdraw up to {formatMoney(source.available, 'NGN')} from {source.pocket
										.name}.{isZero(source.reserved)
										? ''
										: ` ${formatMoney(source.reserved, 'NGN')} is already reserved for an open request.`}
								</p>
							{/if}
						</div>

						<div class="mm-field">
							<span class="mm-field-label">To payout account</span>
							{#if data.payoutAccounts.length === 0}
								<p class="mm-note">
									Add a bank account first. <a class="mm-link" href="/app/payout-accounts/add"
										>Add payout account</a
									>
								</p>
							{:else}
								<div class="mm-box">
									<span class="bank" aria-hidden="true"
										><Landmark size={18} strokeWidth={1.6} /></span
									>
									<div class="mm-names">
										<span class="mm-box-title"
											>{account ? accountTitle(account) : 'Choose an account'}</span
										>
										{#if account}
											<span class="mm-box-sub"
												>{account.accountName} · {account.usable
													? 'Verified'
													: 'Not usable yet'}{account.isPrimary ? ' · Primary' : ''}</span
											>
										{/if}
									</div>
									{#if data.payoutAccounts.length > 1}
										<button
											type="button"
											class="mm-link"
											aria-expanded={chooseAccount}
											onclick={() => (chooseAccount = !chooseAccount)}>Change</button
										>
									{/if}
								</div>
								{#if chooseAccount}
									<div class="accounts" role="radiogroup" aria-label="Payout account">
										{#each data.payoutAccounts as a (a.payoutAccountId)}
											<button
												type="button"
												role="radio"
												class="mm-pocket"
												aria-checked={payoutAccountId === a.payoutAccountId}
												disabled={!a.usable}
												onclick={() => {
													payoutAccountId = a.payoutAccountId;
													chooseAccount = false;
												}}
											>
												<span class="mm-box-title">{accountTitle(a)}</span>
												<span class="mm-pocket-sub"
													>{a.accountName}{a.usable ? '' : ' · can’t receive yet'}</span
												>
											</button>
										{/each}
									</div>
								{/if}
							{/if}
						</div>

						<div class="mm-actions end">
							<a class="mm-btn grow-0" href="/app/withdrawals">Cancel</a>
							<button
								type="submit"
								class="mm-btn primary grow-0"
								disabled={!shell.canAct || shell.paused('withdrawals') || view.savedAt !== null}
								>Continue to review</button
							>
						</div>
					</form>
					<div class="art" aria-hidden="true">
						<div class="shade"></div>
						<RootImage pose="withdraw" class="art-root" sizes="300px" eager />
					</div>
				{:else if source && amount && account && !wide.current}
					<!-- Paper M10: the amount, then where it goes; the PIN sheet confirms. -->
					<section class="m10" aria-label="Review your withdrawal">
						<div class="m10-head">
							<span class="avail">You’re withdrawing</span>
							<span class="m10-amount">{formatMoney(amount, 'NGN')}</span>
						</div>
						<dl class="m10-rows">
							<div>
								<dt>From</dt>
								<dd>{source.pocket.name} pocket · NGN</dd>
							</div>
							<div>
								<dt>To</dt>
								<dd>{accountTitle(account)}</dd>
							</div>
							<div>
								<dt>Name</dt>
								<dd>{account.accountName}</dd>
							</div>
						</dl>
						{@render reasonBlock()}
						<section class="m10-rows after" aria-labelledby="wd-after">
							<h2 class="m10-label" id="wd-after">After you submit</h2>
							<dl>
								<div>
									<dt>Reserved</dt>
									<dd class="held">+{formatMoney(amount, 'NGN')}</dd>
								</div>
								<div>
									<dt>Available to withdraw</dt>
									<dd>{formatMoney(availableAfter ?? '0', 'NGN')}</dd>
								</div>
								<div>
									<dt>Posted balance</dt>
									<dd>Unchanged until payout</dd>
								</div>
							</dl>
						</section>
						{#if dialogError && !pinOpen}<p class="mm-error center" role="alert">
								{dialogError}
							</p>{/if}
						<div class="m10-foot">
							<button
								type="button"
								class="continue"
								disabled={!shell.canAct ||
									shell.paused('withdrawals') ||
									attempt.state.kind === 'sending'}
								onclick={openPin}>Enter PIN to submit</button
							>
						</div>
					</section>
				{:else if source && amount && account}
					<section class="mm-card">
						<div class="mm-field">
							<span class="mm-muted">You're withdrawing</span>
							<span class="mm-big">{formatMoney(amount, 'NGN')}</span>
						</div>
						<dl class="rows">
							<div>
								<dt>From</dt>
								<dd>{source.pocket.name} pocket · NGN</dd>
							</div>
							<div>
								<dt>To</dt>
								<dd>{accountTitle(account)} · {account.accountName}</dd>
							</div>
							<div>
								<dt>Approval</dt>
								<dd>{source.office.name} leadership</dd>
							</div>
						</dl>
						{@render reasonBlock()}
						<div class="mm-field">
							<span class="mm-label">After you submit</span>
							<dl class="rows">
								<div>
									<dt>Reserved in {source.pocket.name}</dt>
									<dd>
										{formatMoney(source.reserved, 'NGN')} → {formatMoney(
											reservedAfter ?? '0',
											'NGN'
										)}
									</dd>
								</div>
								<div>
									<dt>Available to withdraw</dt>
									<dd>
										{formatMoney(source.available, 'NGN')} → {formatMoney(
											availableAfter ?? '0',
											'NGN'
										)}
									</dd>
								</div>
								<div>
									<dt>Posted balance</dt>
									<dd>{formatMoney(source.posted, 'NGN')} · unchanged until payout</dd>
								</div>
							</dl>
						</div>
						{#if dialogError && !pinOpen}<p class="mm-error" role="alert">{dialogError}</p>{/if}
						<div class="mm-actions spread">
							<button type="button" class="mm-link" onclick={() => (step = 'amount')}
								>Edit amount</button
							>
							<button
								type="button"
								class="mm-btn primary grow-0"
								disabled={!shell.canAct ||
									shell.paused('withdrawals') ||
									attempt.state.kind === 'sending'}
								onclick={openPin}>Submit request</button
							>
						</div>
					</section>
					<aside class="mm-card next">
						<div class="next-head">
							<RootImage pose="withdraw" class="next-root" sizes="56px" />
							<div>
								<p class="mm-box-title">What happens next</p>
								<p class="mm-box-sub">Root walks you through it.</p>
							</div>
						</div>
						<ol class="next-list">
							<li>
								Submitting reserves the amount in {source.pocket.name} straight away, so it can't be spent
								twice.
							</li>
							<li>A leader reviews and approves, then sends the money to your bank.</li>
							<li>Your posted balance changes only once the payout receipt is verified.</li>
						</ol>
						<p class="mm-note tip">
							You can cancel any time before it's approved — the reserved amount goes straight back.
						</p>
					</aside>
				{/if}
			</div>
		{/if}
	</div>

	{#if source && amount && account}
		<ConfirmDialog
			bind:open={pinOpen}
			title="Enter your transaction PIN"
			summary={`To submit ${formatMoney(amount, 'NGN')} to ${accountTitle(account)}`}
			confirmLabel="Submit request"
			needsReason={false}
			busy={attempt.state.kind === 'sending'}
			error={dialogError}
			{pinError}
			onConfirm={submit}
		/>
	{/if}
{/if}

<style>
	.layout {
		display: flex;
		flex-direction: column;
		gap: 24px;
	}

	.layout > .mm-card:first-child {
		flex: 1;
		min-width: 0;
	}

	.art {
		position: relative;
		display: none;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: var(--radius-24);
		background: #1a1d1e url('/auth-bg/desktop-dark.jpg') 70% 40% / cover;
	}

	.art .shade,
	.sent-hero .shade {
		position: absolute;
		inset: 0;
		background: linear-gradient(90deg, #111314e0 0%, #11131400 70%);
	}

	.art :global(.art-root) {
		position: absolute;
		right: 20px;
		bottom: -10px;
		width: 300px;
		height: 400px;
	}

	.bank {
		display: flex;
		flex-shrink: 0;
		align-items: center;
		justify-content: center;
		width: 40px;
		height: 40px;
		border-radius: var(--radius-12);
		background: var(--color-raised);
	}

	.accounts {
		display: grid;
		gap: 8px;
	}

	.end {
		justify-content: flex-end;
	}

	.spread {
		align-items: center;
		justify-content: space-between;
	}

	.grow-0,
	.mm-actions .grow-0 {
		flex: 0 0 auto;
	}

	.rows {
		display: flex;
		flex-direction: column;
		margin: 0;
	}

	.rows div {
		display: flex;
		justify-content: space-between;
		gap: 16px;
		padding: 12px 0;
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.rows dt {
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	.rows dd {
		margin: 0;
		color: var(--color-text);
		font-size: var(--text-14);
		text-align: right;
	}

	.next {
		gap: 16px;
	}

	.next-head {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	.next-head :global(.next-root) {
		width: 56px;
		height: 75px;
	}

	.next-list {
		display: flex;
		flex-direction: column;
		gap: 14px;
		margin: 0;
		padding-left: 20px;
		color: var(--color-text);
		font-size: var(--text-14);
		line-height: 20px;
	}

	.next-list li::marker {
		color: var(--color-accent);
		font-weight: var(--font-weight-semibold);
	}

	.tip {
		padding: 12px 14px;
		border-radius: var(--radius-12);
		background: var(--color-canvas);
	}

	.sent {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 12px;
		max-width: 640px;
		margin: 0 auto;
		text-align: center;
	}

	.sent-hero {
		position: relative;
		width: 100%;
		height: 250px;
		margin-bottom: 16px;
		overflow: clip;
		border-radius: var(--radius-24);
		background: #1a1d1e url('/auth-bg/desktop-dark.jpg') 70% 40% / cover;
	}

	.sent-hero :global(.sent-root) {
		position: absolute;
		left: 0;
		right: 0;
		margin-inline: auto;
		bottom: -6px;
		width: 190px;
		height: 254px;
	}

	.sent-lead {
		max-width: 460px;
		color: var(--color-muted);
		font-size: 15px;
		line-height: 24px;
	}

	.sent-actions {
		margin: 12px 0 4px;
	}

	.sent-actions .mm-btn {
		flex: 0 0 auto;
	}

	/* ── Slice 29: Paper M09 (phone) ── */
	.phone {
		gap: 0;
	}

	.navbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 4px 12px 8px;
	}

	.navbar h1 {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.nav-icon {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 44px;
		height: 44px;
		color: var(--color-text);
		background: none;
		border: 0;
		cursor: pointer;
	}

	.nav-step {
		width: 44px;
		color: var(--color-muted);
		font-size: 13px;
		line-height: 16px;
		text-align: center;
	}

	.m09 {
		display: flex;
		flex-direction: column;
		min-height: calc(100dvh - 60px - env(safe-area-inset-top));
		padding-bottom: env(safe-area-inset-bottom);
	}

	.chip-row {
		display: flex;
		justify-content: center;
		padding: 8px 20px 0;
	}

	.chip-row :global(.pocket-chip) {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		height: 40px;
		padding: 0 14px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: var(--color-surface);
		color: var(--color-text);
		font-size: var(--text-14);
		line-height: 18px;
		cursor: pointer;
	}

	.chip-row :global(.pocket-chip)::before {
		content: '';
		width: 8px;
		height: 8px;
		border-radius: var(--radius-pill);
		background: var(--color-accent);
	}

	.amount-block {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 10px;
		padding: 40px 20px 28px;
	}

	.big-amount {
		display: flex;
		align-items: center;
		gap: 4px;
		color: var(--color-text);
		font-size: 52px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.03em;
		line-height: 60px;
		font-variant-numeric: tabular-nums;
	}

	.big-amount.empty {
		color: color-mix(in oklab, var(--color-text) 40%, transparent);
	}

	.caret {
		width: 2px;
		height: 48px;
		background: var(--color-accent);
		animation: blink 1s steps(1) infinite;
	}

	.avail {
		color: var(--color-muted);
		font-size: 13px;
		line-height: 16px;
	}

	.center {
		text-align: center;
	}

	.use-max {
		height: 32px;
		padding: 0 12px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: color-mix(in oklab, var(--color-text) 85%, transparent);
		font-size: var(--text-12);
		font-weight: var(--font-weight-medium);
		cursor: pointer;
	}

	.to-card {
		display: flex;
		align-items: center;
		gap: 12px;
		margin: 0 20px;
		padding: 12px 14px;
		border: 1px solid #ffffff14;
		border-radius: 14px;
		background: var(--color-surface);
	}

	.to-icon {
		display: flex;
		flex-shrink: 0;
		align-items: center;
		justify-content: center;
		width: 36px;
		height: 36px;
		border-radius: 10px;
		background: var(--color-raised);
		color: var(--color-text);
	}

	.to-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.to-label {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: 16px;
	}

	.to-name {
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.to-card :global(.to-change) {
		padding: 8px 0 8px 8px;
		border: 0;
		background: none;
		color: var(--color-accent);
		font-size: 13px;
		line-height: 16px;
		cursor: pointer;
	}

	.to-card :global(.to-change .wp-chevron) {
		display: none;
	}

	.keypad {
		display: grid;
		flex: 1;
		grid-template-columns: repeat(3, 1fr);
		align-content: end;
		gap: 4px 0;
		padding: 20px 28px 8px;
	}

	.key {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 58px;
		border: 0;
		border-radius: var(--radius-16);
		background: none;
		color: var(--color-text);
		font-size: 26px;
		line-height: 32px;
		cursor: pointer;
		-webkit-tap-highlight-color: transparent;
	}

	.key:active {
		background: var(--color-raised);
	}

	.continue {
		height: 54px;
		margin: 8px 20px 34px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--button-primary-bg);
		box-shadow:
			inset 0 1px 0 #ffffff59,
			0 10px 28px -10px var(--button-primary-glow);
		color: var(--button-primary-ink);
		font-size: var(--text-16);
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.continue:disabled {
		opacity: var(--opacity-disabled);
		cursor: default;
	}

	.phone .layout {
		padding: 0;
	}

	.phone .layout > section.mm-card,
	.phone .layout > aside {
		margin: 0 20px;
	}

	/* ── Paper M10 (phone) ── */
	.m10 {
		display: flex;
		flex-direction: column;
		gap: 24px;
		min-height: calc(100dvh - 60px - env(safe-area-inset-top));
		padding: 24px 20px env(safe-area-inset-bottom);
	}

	.m10-head {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 6px;
	}

	.m10-amount {
		color: var(--color-text);
		font-size: 40px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.03em;
		line-height: 48px;
		font-variant-numeric: tabular-nums;
	}

	.m10-rows {
		display: flex;
		flex-direction: column;
		gap: 14px;
		margin: 0;
		padding: 16px 18px;
		border: 1px solid #ffffff14;
		border-radius: 14px;
		background: var(--color-surface);
	}

	.m10-rows div {
		display: flex;
		justify-content: space-between;
		gap: 16px;
	}

	.m10-rows dt {
		color: var(--color-muted);
		font-size: 13px;
	}

	.m10-rows dd {
		margin: 0;
		color: var(--color-text);
		font-size: 13px;
		text-align: right;
	}

	.m10-foot {
		display: flex;
		flex: 1;
		flex-direction: column;
		justify-content: flex-end;
	}

	.m10-foot .continue {
		margin: 0 0 34px;
	}

	/* ── Blueprint 40, Paper WR01: the reason note ── */
	.reason {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.m10 .reason {
		padding-top: 4px;
	}

	.reason-head {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 12px;
	}

	.reason-label {
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 20px;
	}

	.reason-req,
	.reason-hint {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: 16px;
	}

	.reason-field {
		width: 100%;
		min-height: 84px;
		padding: 14px 16px;
		border: 1.5px solid var(--color-border);
		border-radius: 14px;
		background: var(--color-surface);
		color: var(--color-text);
		font: inherit;
		/* 16px so iOS does not zoom into the field. */
		font-size: var(--text-16);
		line-height: 22px;
		resize: vertical;
	}

	.reason-field::placeholder {
		color: color-mix(in oklab, var(--color-text) 40%, transparent);
	}

	.reason-field:focus {
		border-color: var(--color-accent);
		outline: none;
	}

	.reason-field[aria-invalid='true'] {
		border-color: var(--color-danger);
	}

	.m10-label {
		margin: 0;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		font-weight: normal;
		letter-spacing: 0.08em;
		line-height: 16px;
		text-transform: uppercase;
	}

	.m10-rows.after dl {
		display: flex;
		flex-direction: column;
		gap: 14px;
		margin: 0;
	}

	.m10-rows.after dt {
		color: color-mix(in oklab, var(--color-text) 85%, transparent);
	}

	.m10-rows dd.held {
		color: var(--color-warning);
	}

	@keyframes blink {
		50% {
			opacity: 0;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.caret {
			animation: none;
		}
	}

	@media (min-width: 1024px) {
		.layout {
			flex-direction: row;
			align-items: stretch;
		}

		.art {
			display: block;
			width: 360px;
			flex-shrink: 0;
		}

		.next {
			align-self: flex-start;
			width: 360px;
			flex-shrink: 0;
		}
	}
</style>
