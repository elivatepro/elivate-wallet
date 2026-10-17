<!--
	Adjustment (W-14), Paper "App — Screens v1" E05 (desktop) / E06 (mobile),
	confirm + PIN "App — Screens v4" MV02 and result MV03. A leader with
	"manual credit/debit adjustment" credits or debits a member's money in one
	currency with a reason and at least one evidence file, always with the PIN
	(owner decision 2026-10-08). The split follows the network's policy and is
	fixed when it is submitted; it posts once an evidence reviewer clears it.
	Opened from a member's wallet or detail (?member=) or by picking a member.
-->
<script lang="ts">
	import { enterMovesOn } from '#lib/ui/enter-moves-on.js';
	import { getContext, untrack } from 'svelte';
	import { page } from '$app/state';
	import { Cause, Effect, Exit, Option } from 'effect';
	import X from '@lucide/svelte/icons/x';
	import {
		Entry,
		EntryAppRoutes,
		EntrySegments,
		EntryTargetPage,
		type EntryTarget
	} from '#lib/contract/entries.js';
	import type { Currency } from '#lib/contract/ledger.js';
	import { UUID_PATTERN } from '#lib/contract/common.js';
	import { getJson } from '#lib/client/api.js';
	import { loadView } from '#lib/client/org.svelte.js';
	import { cachedPage, MorePages, type PageLoaded } from '#lib/client/page-cache.svelte.js';
	import { CommandAttempt, showsRecovery } from '#lib/client/command-attempt.svelte.js';
	import { EntryEvidence } from '#lib/client/entry-evidence.svelte.js';
	import { submitEntry } from '#lib/client/entry-submit.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { ADJUSTMENT_REASONS, entryMessage, signedEntryAmount } from '#lib/entries.js';
	import { allocate, groupAmount, parseAmount, pocketColor, shortPercent } from '#lib/income.js';
	import { currencySymbol, formatMoney, isZero } from '#lib/money.js';
	import Outcome from '#lib/ui/app/Outcome.svelte';
	import OutcomeUnknown from '#lib/ui/app/OutcomeUnknown.svelte';
	import IncomeConfirm from '#lib/ui/income/IncomeConfirm.svelte';
	import MemberPicker from '#lib/ui/income/MemberPicker.svelte';
	import EvidencePicker from '#lib/ui/money/EvidencePicker.svelte';
	import '#lib/ui/money/entry.css';
	import NoAccess from '#lib/ui/app/NoAccess.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';

	const shell = getContext<Shell>('shell');
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);
	const OTHER = 'other';

	let denied = $state(false);
	let target = $state<EntryTarget | null>(null);
	let direction = $state<'credit' | 'debit'>('credit');
	let currency = $state<Currency>('NGN');
	let amountText = $state('');
	let reasonChoice = $state<string>(ADJUSTMENT_REASONS[0]);
	let reasonOther = $state('');
	let formError = $state<string | null>(null);
	let busy = $state(false);
	const evidence = new EntryEvidence();
	/** Opened with ?member=: the member is fixed (E05 shows them, no picker). */
	const fixedMember = $derived(page.url.searchParams.get('member'));

	const attempt = new CommandAttempt({
		command: 'submit_adjustment',
		path: EntryAppRoutes.adjustments,
		method: 'POST',
		schema: Entry,
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
	const recovering = $derived(showsRecovery(attempt));
	const result = $derived(attempt.state.kind === 'done' ? attempt.state.result : null);
	const failureOf = <A, E>(exit: Exit.Exit<A, E>) =>
		Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) : undefined;

	// Blueprint 23: the default (unsearched) member list opens from cache, then
	// refreshes; searches and "load more" pages are never cached. Opened with
	// ?member=, only that member's pockets are read.
	async function loadTargets(): Promise<PageLoaded<EntryTargetPage>> {
		const exit = await Effect.runPromiseExit(
			getJson(`${EntryAppRoutes.targets}?kind=adjustment`, EntryTargetPage)
		);
		if (Exit.isSuccess(exit)) {
			denied = false;
			return { ok: true, value: exit.value };
		}
		const failure = failureOf(exit);
		denied = failure?._tag === 'BackendError' && failure.code === 'authorization_denied';
		if (denied) targetView.clear();
		return { ok: false, text: 'We couldn’t load your members.', status: null };
	}
	const targetView = cachedPage(shell, {
		kind: 'entries',
		part: () => 'adjustment-targets',
		enabled: () => !fixedMember,
		load: loadTargets
	});
	const pages = new MorePages<EntryTarget>(() => targetView.data);
	const targets = $derived(pages.items);
	const nextCursor = $derived(pages.nextCursor);
	const loadingMore = $derived(pages.loading);
	const loadMore = () =>
		pages.more((cursor) =>
			loadView(
				`${EntryAppRoutes.targets}?kind=adjustment&cursor=${encodeURIComponent(cursor)}`,
				EntryTargetPage
			)
		);

	async function search(query: string, cursor: string | null) {
		// Built and read once per call; not reactive state.
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const params = new URLSearchParams({ kind: 'adjustment', q: query });
		if (cursor) params.set('cursor', cursor);
		const exit = await Effect.runPromiseExit(
			getJson(`${EntryAppRoutes.targets}?${params}`, EntryTargetPage)
		);
		return Exit.isSuccess(exit) ? exit.value : null;
	}

	// Blueprint 23: a member's pockets and split open from their cached copy
	// (per member), then refresh; the newest member read wins. Review waits for
	// the fresh read, and the server checks everything on submit.
	/** The member whose pockets are shown (lower case); null until one is chosen. */
	let memberId = $state<string | null>(page.url.searchParams.get('member')?.toLowerCase() ?? null);
	let segFailure = $state<{ id: string; text: string } | null>(null);
	async function loadSegments(): Promise<PageLoaded<EntrySegments>> {
		const id = memberId ?? '';
		const params = new URLSearchParams({ kind: 'adjustment', membershipId: id });
		const exit = await Effect.runPromiseExit(
			getJson(`${EntryAppRoutes.segments}?${params}`, EntrySegments)
		);
		if (Exit.isSuccess(exit)) {
			if (segFailure?.id === id) segFailure = null;
			return { ok: true, value: exit.value };
		}
		const text = entryMessage(failureOf(exit));
		segFailure = { id, text };
		return { ok: false, text, status: null };
	}
	const segView = cachedPage(shell, {
		kind: 'entries',
		part: () => (memberId ? `seg-${memberId}` : undefined),
		enabled: () => memberId !== null,
		cacheable: () => memberId !== null && UUID_PATTERN.test(memberId),
		load: loadSegments
	});
	const segments = $derived<EntrySegments | null>(
		segView.data && segView.data.membershipId === memberId ? segView.data : null
	);
	/** The pockets shown came from the server just now, not from the cache. */
	const segFresh = $derived(segments !== null && segView.savedAt === null);
	const segError = $derived(
		!segments && segFailure && segFailure.id === memberId ? segFailure.text : null
	);
	const loadError = $derived(
		denied
			? 'Adjustments are for leaders with that permission.'
			: fixedMember
				? segError
				: targetView.data
					? null
					: targetView.error
	);

	function loadMember(membershipId: string) {
		formError = null;
		const id = membershipId.toLowerCase();
		if (id === memberId) void segView.reload();
		else memberId = id;
	}

	/** The member's first currency for a new member; a choice survives a refresh. */
	let currencyFor: string | null = null;
	$effect(() => {
		const s = segments;
		if (!s) return;
		untrack(() => {
			if (s.office) {
				target = {
					membershipId: s.membershipId,
					person: s.person,
					role: s.role,
					officeId: s.office.id,
					officeName: s.office.name
				};
			}
			const first = (s.currencies[0]?.code as Currency | undefined) ?? 'NGN';
			if (currencyFor !== s.membershipId) currency = first;
			else if (!s.currencies.some((c) => c.code === currency)) currency = first;
			currencyFor = s.membershipId;
		});
	});

	const amount = $derived(parseAmount(amountText, 2));
	const reason = $derived(reasonChoice === OTHER ? reasonOther.trim() : reasonChoice);
	const pockets = $derived(segments?.allocation?.pockets ?? []);
	const preview = $derived(
		amount
			? allocate(
					amount,
					2,
					pockets.map((p) => ({ pocketId: p.pocketId, name: p.name, basisPoints: p.basisPoints }))
				)
			: pockets.map((p) => ({ ...p, amount: null }))
	);
	const signed = $derived(
		amount ? formatMoney(direction === 'debit' ? `-${amount}` : amount, currency, true) : null
	);
	const who = $derived(target?.person?.name ?? target?.person?.uid ?? 'the member');
	const uid = $derived(target?.person?.uid ?? '');

	function validate(): string | null {
		if (!target || !segments) return 'Choose the member.';
		if (!segments.allocation) return 'The network has no split yet.';
		if (!amount) return 'Enter the amount.';
		if (reason.length < 3 || reason.length > 500) return 'Give a reason (3–500 characters).';
		if (evidence.files.length === 0) return 'Add at least one evidence file.';
		return null;
	}

	let confirmOpen = $state(false);
	let pinError = $state<string | null>(null);
	let confirmError = $state<string | null>(null);

	/**
	 * Closing the PIN prompt drops a refused new attempt, so an edited form never
	 * resends the old body; an attempt still being recovered is always kept (F-03).
	 */
	$effect(() => {
		if (!confirmOpen && attempt.awaitingPin && !attempt.recovering) attempt.reset();
	});

	function review() {
		const problem = validate();
		if (problem) return void (formError = problem);
		if (!segFresh) {
			const failed = segFailure?.id === memberId ? segFailure.text : null;
			return void (formError = failed ?? 'Still updating the pockets. Try again in a moment.');
		}
		formError = null;
		pinError = null;
		confirmError = null;
		confirmOpen = true;
	}

	async function submit(pin: string | undefined) {
		if (!workspaceId || !target || !amount) return;
		if (!pin) return void (pinError = 'Enter your PIN.');
		busy = true;
		pinError = null;
		confirmError = null;
		const outcome = await submitEntry({
			attempt,
			evidence,
			kind: 'adjustment',
			targetMembershipId: target.membershipId,
			workspaceId,
			body: { targetMembershipId: target.membershipId, direction, currency, amount, reason },
			summary: `${signed} adjustment for ${who}`,
			pin
		});
		busy = false;
		switch (outcome.kind) {
			case 'done':
			case 'unknown':
				confirmOpen = false;
				return;
			case 'locked':
				return void window.location.assign('/pin/locked');
			case 'pin':
				pinError = outcome.message;
				return;
			case 'refused':
				confirmError = entryMessage(outcome.failure);
		}
	}

	function another() {
		attempt.reset();
		amountText = '';
		evidence.clear();
	}
	const firstOf = (name: string | null | undefined) => (name ?? 'the member').split(' ')[0];
</script>

<svelte:head><title>Adjustment · Elivate Wallet</title></svelte:head>

{#if recovering}
	<OutcomeUnknown
		{attempt}
		noun="adjustment"
		backHref="/app/adjust"
		backLabel="Back to adjustment"
	/>
{:else if result}
	<Outcome
		pose="adjust"
		title="Adjustment sent for checking"
		lead={`${signedEntryAmount(result)} for ${firstOf(result.member?.name)} posts once the evidence is verified.`}
		footnote={result.reference}
	>
		{#snippet actions()}
			<a class="out-ghost" href={`/app/wallets?wallet=${result.walletId}`}>Back to member</a>
			<a class="out-primary" href="/app" onclick={another}>Done</a>
		{/snippet}
	</Outcome>
{:else}
	<header class="en-bar">
		<a href="/app" aria-label="Close"><X size={22} strokeWidth={1.8} /></a>
		<h1>Adjustment</h1>
		<span></span>
	</header>
	<div class="en-page">
		{#if denied}
			<NoAccess lead={loadError ?? undefined} headingLevel={2} plain />
		{:else if loadError}
			<p class="mm-empty" role="alert">{loadError}</p>
		{:else}
			<form
				class="en-layout"
				{@attach enterMovesOn}
				onsubmit={(e) => {
					e.preventDefault();
					review();
				}}
				novalidate
			>
				<div class="en-card">
					{#if formError ?? segError}<p class="en-error" role="alert">
							{formError ?? segError}
						</p>{/if}
					{#if fixedMember}
						<div class="en-field">
							<span class="en-label">Member</span>
							<div class="en-box member">
								<span class="avatar" aria-hidden="true"
									>{who
										.split(' ')
										.map((p) => p[0])
										.slice(0, 2)
										.join('')}</span
								>
								<span class="member-text">
									<span class="member-name">{who}</span>
									<span class="en-hint">{uid}{target ? ` · ${target.officeName}` : ''}</span>
								</span>
							</div>
						</div>
					{:else}
						<MemberPicker
							{targets}
							bind:selected={target}
							hasMore={!!nextCursor}
							{loadingMore}
							onLoadMore={loadMore}
							onChange={(t) => loadMember(t.membershipId)}
							{search}
						/>
					{/if}

					{#if segments}
						<div class="en-row two">
							<div class="en-field">
								<span class="en-label" id="adj-direction">Direction</span>
								<div class="en-seg" role="group" aria-labelledby="adj-direction">
									<button
										type="button"
										aria-pressed={direction === 'credit'}
										onclick={() => (direction = 'credit')}>Credit</button
									>
									<button
										type="button"
										aria-pressed={direction === 'debit'}
										onclick={() => (direction = 'debit')}>Debit</button
									>
								</div>
							</div>
							<div class="en-field">
								<span class="en-label" id="adj-currency">Currency</span>
								<div class="en-seg" role="group" aria-labelledby="adj-currency">
									{#each segments.currencies as c (c.code)}
										<button
											type="button"
											aria-pressed={currency === c.code}
											onclick={() => (currency = c.code)}>{currencySymbol(c.code)} {c.code}</button
										>
									{/each}
								</div>
							</div>
						</div>

						<div class="en-field">
							<label class="en-label" for="adj-amount">Amount</label>
							<div class="en-box tall">
								<input
									id="adj-amount"
									class="en-input huge"
									inputmode="decimal"
									autocomplete="off"
									placeholder={`${currencySymbol(currency)}0.00`}
									bind:value={amountText}
									onblur={() =>
										amount && (amountText = `${currencySymbol(currency)}${groupAmount(amount)}`)}
								/>
							</div>
						</div>

						<div class="en-field">
							<label class="en-label" for="adj-reason">Reason</label>
							<WheelPicker
								id="adj-reason"
								class="en-box"
								label="Reason"
								options={[
									...ADJUSTMENT_REASONS.map((r) => ({ value: r, label: r })),
									{ value: OTHER, label: 'Other…' }
								]}
								value={reasonChoice}
								onchange={(v) => (reasonChoice = v)}
							/>
							{#if reasonChoice === OTHER}
								<div class="en-box">
									<input
										class="en-input"
										maxlength="500"
										autocomplete="off"
										placeholder="Say why, in a few words"
										aria-label="Reason in your words"
										bind:value={reasonOther}
									/>
								</div>
							{/if}
						</div>

						<EvidencePicker {evidence} label="Evidence" addTitle="Upload the approval or proof" />

						<!-- Mobile split (E06). -->
						<div class="en-mobile-sum en-mobile-only">
							{#each preview.filter((l) => l.amount === null || !isZero(l.amount)) as line (line.pocketId)}
								<div>
									<span>{line.name} · {shortPercent(line.basisPoints)}%</span>
									<span>{line.amount ? formatMoney(line.amount, currency) : '—'}</span>
								</div>
							{/each}
						</div>
						<button
							type="submit"
							class="en-primary en-mobile-only"
							disabled={!shell.canAct || shell.paused('adjustments') || busy}
							>Submit adjustment</button
						>
					{/if}
				</div>

				<aside class="en-side en-desktop-only" aria-label="Split by allocation policy">
					<div class="en-summary">
						<div class="en-sum-block">
							<span class="en-kicker">Split by allocation policy</span>
							<span class="en-big {direction === 'debit' ? 'debit' : 'credit'}"
								>{signed ?? '—'}</span
							>
						</div>
						<div class="en-sum-block">
							{#each preview as line, i (line.pocketId)}
								<div class="en-line">
									<span
										><span class="en-dot" style:background={pocketColor(i)} aria-hidden="true"
										></span>{line.name} · {shortPercent(line.basisPoints)}%</span
									>
									<span class="v">{line.amount ? formatMoney(line.amount, currency) : '—'}</span>
								</div>
							{/each}
						</div>
						<div class="en-sum-block">
							<button
								type="submit"
								class="en-primary"
								disabled={!shell.canAct || shell.paused('adjustments') || busy}
								>Submit adjustment</button
							>
						</div>
					</div>
				</aside>
			</form>
		{/if}
	</div>
{/if}

<IncomeConfirm
	bind:open={confirmOpen}
	title={`Submit ${signed ?? ''}?`}
	lead="Split by the network’s policy once the evidence is verified"
	rows={[
		{ label: direction === 'debit' ? 'From' : 'To', value: `${who}${uid ? ` · ${uid}` : ''}` },
		{ label: 'Reason', value: reason || '—' },
		{
			label: 'Evidence',
			value:
				evidence.files.length === 1
					? (evidence.files[0]?.file.name ?? '')
					: `${evidence.files.length} files`
		}
	]}
	confirmLabel="Submit adjustment"
	{busy}
	error={confirmError}
	{pinError}
	onConfirm={({ pin }) => submit(pin)}
/>

<style>
	.member {
		justify-content: flex-start;
	}

	.avatar {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 32px;
		height: 32px;
		border-radius: 999px;
		background: var(--color-accent-subtle, #3a251f);
		color: var(--color-accent);
		font-size: 12px;
		font-weight: var(--font-weight-semibold);
	}

	.member-text {
		display: flex;
		flex-direction: column;
		gap: 1px;
	}

	.member-name {
		color: var(--color-text);
		font-size: 15px;
		line-height: 18px;
	}

	.tall {
		height: 72px;
		border-color: var(--color-accent);
	}

	.huge {
		font-size: 32px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 40px;
	}

	@media (min-width: 1024px) {
		.two {
			align-items: stretch;
		}
	}
</style>
