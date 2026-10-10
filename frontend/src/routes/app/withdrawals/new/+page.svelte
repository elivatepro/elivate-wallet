<!--
	Request a withdrawal (W-09), Paper "App — Screens v1" M06 (amount) → M07
	(review + PIN) → M08 (request sent); mobile M09–M11. Unknown outcome (B16 /
	B16d) is the shared F-03 recovery screen bound to the same attempt.

	NGN only: pick a pocket with money available, an amount up to what it has
	available (requests already open are reserved), and a usable payout
	account (verified, not cooling off, name not mismatched). Submitting needs
	a fresh PIN and reserves the amount at once; the posted balance changes
	only once the payout receipt is verified.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import Landmark from '@lucide/svelte/icons/landmark';
	import {
		Withdrawal,
		WithdrawalAppRoutes,
		WithdrawalSources,
		type WithdrawalSource
	} from '#lib/contract/withdrawals.js';
	import { getJson } from '#lib/client/api.js';
	import { CommandAttempt } from '#lib/client/command-attempt.svelte.js';
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

	let data = $state<WithdrawalSources | null>(null);
	let loadError = $state<string | null>(null);
	let denied = $state(false);
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

	async function load() {
		const exit = await Effect.runPromiseExit(
			getJson(WithdrawalAppRoutes.sources, WithdrawalSources)
		);
		if (Exit.isSuccess(exit)) {
			data = exit.value;
			const firstSource = exit.value.sources.find((s) => !isZero(s.available));
			sourceId ??= firstSource?.accountId ?? null;
			const usable = exit.value.payoutAccounts.filter((a) => a.usable);
			payoutAccountId ??= (usable.find((a) => a.isPrimary) ?? usable[0])?.payoutAccountId ?? null;
			loadError = null;
			denied = false;
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		denied = failure?._tag === 'BackendError' && failure.code === 'authorization_denied';
		loadError = denied
			? 'Withdrawals aren’t open to you in this network.'
			: 'We couldn’t load your pockets.';
	}
	$effect(() => {
		if (shell.state.kind === 'ready' && !data && !loadError) void load();
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

	function openPin() {
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
					{ accountId: source.accountId, amount, payoutAccountId: account.payoutAccountId },
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
			data = null;
			void load();
		}
	}

	const reservedAfter = $derived(source && amount ? sumMoney([source.reserved, amount]) : null);
	const availableAfter = $derived(
		source && amount ? sumMoney([source.available, `-${amount}`]) : null
	);
</script>

<svelte:head><title>New withdrawal · Elivate Wallet</title></svelte:head>

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
	<div class="mm-page">
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
			<li aria-current={pinOpen ? 'step' : undefined}><span class="n">3</span> Confirm with PIN</li>
		</ol>

		{#if !data && !loadError}
			<div class="mm-skeleton" aria-hidden="true"></div>
		{:else if loadError || !data}
			<p class="mm-empty" role="alert">{loadError}</p>
		{:else if data.sources.length === 0}
			<p class="mm-empty">You don’t have money to withdraw in this network yet.</p>
		{:else}
			<div class="layout">
				{#if step === 'amount'}
					<form class="mm-card" onsubmit={toReview} novalidate>
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
							<button type="submit" class="mm-btn primary grow-0" disabled={!shell.canAct}
								>Continue to review</button
							>
						</div>
					</form>
					<div class="art" aria-hidden="true">
						<div class="shade"></div>
						<RootImage pose="withdraw" class="art-root" sizes="300px" eager />
					</div>
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
								disabled={!shell.canAct || attempt.state.kind === 'sending'}
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

	.grow-0 {
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
		left: 50%;
		bottom: -6px;
		width: 190px;
		height: 254px;
		transform: translateX(-50%);
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
