<!--
	Record conversion (W-12), Paper "App — Screens v1" B07 (desktop) / B08
	(mobile), result "App — Screens v4" MV04. A leader with "perform currency
	conversion" records a conversion done outside the app: the member's pocket,
	what was converted, what actually arrived, the provider, when, the quoted
	rate if known, and the evidence. The rate actually used is worked out from
	the two amounts; no tolerance or reference rate (owner decision). The
	converted amount is held until an evidence reviewer clears it. Opened from
	its own menu item or a member's wallet ("Convert", ?member=).
-->
<script lang="ts">
	import { enterMovesOn } from '#lib/ui/enter-moves-on.js';
	import { getContext, untrack } from 'svelte';
	import { page } from '$app/state';
	import { Cause, Effect, Exit, Option } from 'effect';
	import ArrowRight from '@lucide/svelte/icons/arrow-right';
	import X from '@lucide/svelte/icons/x';
	import {
		Entry,
		EntryAppRoutes,
		EntrySegments,
		EntryTargetPage,
		RATE_PATTERN,
		type EntrySegment,
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
	import {
		differenceFromQuote,
		effectiveRate,
		entryMessage,
		formatRate,
		localMoment,
		localNow,
		rateBase
	} from '#lib/entries.js';
	import { groupAmount, parseAmount, pocketColor } from '#lib/income.js';
	import { currencySymbol, formatMoney, isZero } from '#lib/money.js';
	import RootDialog from '#lib/ui/account/RootDialog.svelte';
	import Outcome from '#lib/ui/app/Outcome.svelte';
	import OutcomeUnknown from '#lib/ui/app/OutcomeUnknown.svelte';
	import MemberPicker from '#lib/ui/income/MemberPicker.svelte';
	import EvidencePicker from '#lib/ui/money/EvidencePicker.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import '#lib/ui/money/entry.css';
	import NoAccess from '#lib/ui/app/NoAccess.svelte';

	const shell = getContext<Shell>('shell');
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);

	let denied = $state(false);
	let target = $state<EntryTarget | null>(null);
	let sourceId = $state<string | null>(null);
	let amountText = $state('');
	let receivedText = $state('');
	let provider = $state('');
	let quotedText = $state('');
	let convertedAt = $state(localNow());
	let formError = $state<string | null>(null);
	let busy = $state(false);
	const evidence = new EntryEvidence();

	const attempt = new CommandAttempt({
		command: 'submit_conversion',
		path: EntryAppRoutes.conversions,
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
	// refreshes; searches and "load more" pages are never cached.
	async function loadTargets(): Promise<PageLoaded<EntryTargetPage>> {
		const exit = await Effect.runPromiseExit(
			getJson(`${EntryAppRoutes.targets}?kind=conversion`, EntryTargetPage)
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
		part: () => 'conversion-targets',
		load: loadTargets
	});
	const pages = new MorePages<EntryTarget>(() => targetView.data);
	const targets = $derived(pages.items);
	const nextCursor = $derived(pages.nextCursor);
	const loadingMore = $derived(pages.loading);
	const loadError = $derived(
		denied
			? 'Recording conversions is for leaders with that permission.'
			: targetView.data
				? null
				: targetView.error
	);
	const loadMore = () =>
		pages.more((cursor) =>
			loadView(
				`${EntryAppRoutes.targets}?kind=conversion&cursor=${encodeURIComponent(cursor)}`,
				EntryTargetPage
			)
		);

	// Opened from a member's wallet (?member=): choose them once the list is shown.
	let preselected = false;
	$effect(() => {
		const first = targetView.data;
		if (!first || preselected) return;
		preselected = true;
		untrack(() => {
			const wanted = page.url.searchParams.get('member');
			const pre = first.items.find((t) => t.membershipId === wanted);
			if (pre && !target) choose(pre);
			else if (wanted && !target) choose({ membershipId: wanted } as EntryTarget, true);
		});
	});

	async function search(query: string, cursor: string | null) {
		// Built and read once per call; not reactive state.
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const params = new URLSearchParams({ kind: 'conversion', q: query });
		if (cursor) params.set('cursor', cursor);
		const exit = await Effect.runPromiseExit(
			getJson(`${EntryAppRoutes.targets}?${params}`, EntryTargetPage)
		);
		return Exit.isSuccess(exit) ? exit.value : null;
	}

	// Blueprint 23: a member's pockets open from their cached copy (per member),
	// then refresh; the newest member read wins. Submitting waits for the fresh
	// read, and the server checks the balance either way.
	/** The member whose pockets are shown (lower case); null until one is chosen. */
	let memberId = $state<string | null>(null);
	let segFailure = $state<{ id: string; text: string } | null>(null);
	/** Opened from a wallet: the picker is filled from the pockets read. */
	let adopting = false;
	async function loadSegments(): Promise<PageLoaded<EntrySegments>> {
		const id = memberId ?? '';
		const params = new URLSearchParams({ kind: 'conversion', membershipId: id });
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

	/** Loads the member's pockets; `adopt` fills the picker from them (opened from a wallet). */
	function choose(t: EntryTarget, adopt = false) {
		sourceId = null;
		formError = null;
		adopting = adopt;
		if (!adopt) target = t;
		const id = t.membershipId.toLowerCase();
		if (id === memberId) void segView.reload();
		else memberId = id;
	}

	$effect(() => {
		const s = segments;
		if (!s || !adopting || !s.office) return;
		const office = s.office;
		untrack(() => {
			adopting = false;
			target = {
				membershipId: s.membershipId,
				person: s.person,
				role: s.role,
				officeId: office.id,
				officeName: office.name
			};
		});
	});

	const sources = $derived<EntrySegment[]>(
		(segments?.segments ?? []).filter((s) => s.kind === 'ordinary' && !isZero(s.available))
	);
	const source = $derived(sources.find((s) => s.accountId === sourceId) ?? null);
	// The first pocket by default; a choice survives fresh pockets replacing cached ones.
	$effect(() => {
		const list = sources;
		untrack(() => {
			if (!list.some((s) => s.accountId === sourceId)) sourceId = list[0]?.accountId ?? null;
		});
	});
	const others = $derived<Currency[]>(
		(segments?.currencies ?? [])
			.map((c) => c.code)
			.filter((c): c is Currency => c !== source?.currency)
	);
	let destinationChoice = $state<Currency | null>(null);
	const destination = $derived<Currency | null>(
		destinationChoice && others.includes(destinationChoice)
			? destinationChoice
			: (others[0] ?? null)
	);
	const amount = $derived(parseAmount(amountText, 2));
	const received = $derived(parseAmount(receivedText, 2));
	const quoted = $derived.by(() => {
		const cleaned = quotedText.replace(/[₦$,\s]|per.*$/gi, '');
		return cleaned && RATE_PATTERN.test(cleaned) ? cleaned : null;
	});
	const rate = $derived(
		source && destination && amount && received
			? effectiveRate(amount, source.currency, received, destination)
			: null
	);
	const base = $derived(source && destination ? rateBase(source.currency, destination) : null);
	const quote = $derived(
		base && source && destination
			? base === source.currency
				? destination
				: source.currency
			: null
	);
	const difference = $derived(
		source && destination && amount && received
			? differenceFromQuote(amount, source.currency, received, destination, quoted)
			: null
	);
	const first = $derived(
		(target?.person?.name ?? target?.person?.uid ?? 'the member').split(' ')[0] ?? 'the member'
	);
	const money = (value: string, c: Currency) => formatMoney(value, c);

	function validate(): string | null {
		if (!target || !segments) return 'Choose the member.';
		if (!source) return 'Choose the pocket the money was converted from.';
		if (!destination) return 'There’s no other currency to convert into.';
		if (!amount) return 'Enter the amount converted.';
		if (!received) return 'Enter the amount actually received.';
		if (provider.trim().length === 0) return 'Enter the provider.';
		if (quotedText.trim() && !quoted) return 'Check the quoted rate, like 1525.00.';
		if (!localMoment(convertedAt)) return 'Check when it was converted.';
		if (evidence.files.length === 0) return 'Add the evidence of the conversion.';
		return null;
	}

	// ── Submit (PIN only when the 5-minute window isn't open) ──
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
		if (!segFresh) {
			const failed = segFailure?.id === memberId ? segFailure.text : null;
			return void (formError = failed ?? 'Still updating the pockets. Try again in a moment.');
		}
		if (!workspaceId || !target || !source || !destination || !amount || !received) return;
		formError = null;
		busy = true;
		const outcome = await submitEntry({
			attempt,
			evidence,
			kind: 'conversion',
			targetMembershipId: target.membershipId,
			workspaceId,
			body: {
				sourceAccountId: source.accountId,
				amount,
				destinationCurrency: destination,
				destinationAmount: received,
				...(quoted ? { quotedRate: quoted } : {}),
				provider: provider.trim(),
				convertedAt: localMoment(convertedAt)
			},
			summary: `${money(amount, source.currency)} → ${money(received, destination)} for ${first}`,
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

	function another() {
		attempt.reset();
		amountText = '';
		receivedText = '';
		quotedText = '';
		convertedAt = localNow();
		evidence.clear();
		if (target) void choose(target);
	}

	const submitted = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' })
			.format(new Date(iso))
			.replace(' at ', ', ');
</script>

<svelte:head><title>Record conversion · Elivate Wallet</title></svelte:head>

{#if recovering}
	<OutcomeUnknown
		{attempt}
		noun="conversion"
		backHref="/app/convert"
		backLabel="Back to conversions"
	/>
{:else if result && result.conversion}
	<Outcome
		pose="convert"
		title="Conversion sent for checking"
		lead={`${money(result.amount, result.currency)} → ${money(result.conversion.destinationAmount, result.conversion.destinationCurrency)} for ${(result.member?.name ?? 'the member').split(' ')[0]} posts once it’s verified.`}
		footnote={`Submitted ${submitted(result.createdAt)}`}
	>
		{#snippet actions()}
			<a class="out-ghost" href={`/app/wallets?wallet=${result.walletId}`}>View wallet</a>
			<button type="button" class="out-primary" onclick={another}>Record another</button>
		{/snippet}
	</Outcome>
{:else}
	<header class="en-bar">
		<a href="/app" aria-label="Close"><X size={22} strokeWidth={1.8} /></a>
		<h1>Record conversion</h1>
		<span></span>
	</header>
	<div class="en-page">
		{#if denied}
			<NoAccess lead={loadError ?? undefined} headingLevel={2} />
		{:else if loadError}
			<p class="mm-empty" role="alert">{loadError}</p>
		{:else}
			<form
				class="en-layout"
				{@attach enterMovesOn}
				onsubmit={(e) => {
					e.preventDefault();
					void submit();
				}}
				novalidate
			>
				<div class="en-card">
					{#if formError ?? segError}<p class="en-error" role="alert">
							{formError ?? segError}
						</p>{/if}
					<MemberPicker
						{targets}
						bind:selected={target}
						hasMore={!!nextCursor}
						{loadingMore}
						onLoadMore={loadMore}
						onChange={(t) => choose(t as EntryTarget)}
						{search}
					/>

					{#if segments}
						<div class="en-field">
							<label class="en-label" for="cnv-pocket">Pocket</label>
							<div class="en-box">
								{#if source}<span
										class="en-dot"
										style:background={pocketColor(
											sources.findIndex((s) => s.accountId === source.accountId)
										)}
										aria-hidden="true"
									></span>{/if}
								<WheelPicker
									id="cnv-pocket"
									class="en-input"
									label="Pocket"
									placeholder="No pocket has money to convert"
									disabled={sources.length === 0}
									options={sources.map((s) => ({
										value: s.accountId,
										label: s.pocket,
										hint: `${money(s.available, s.currency)} available in ${s.currency}`
									}))}
									bind:value={sourceId}
								/>
							</div>
						</div>

						<div class="en-row">
							<div class="en-field">
								<label class="en-label" for="cnv-amount">Converted from</label>
								<div class="en-box">
									<input
										id="cnv-amount"
										class="en-input big"
										inputmode="decimal"
										autocomplete="off"
										placeholder={source ? `${currencySymbol(source.currency)}0.00` : '0.00'}
										bind:value={amountText}
										onblur={() =>
											amount &&
											(amountText = `${source ? currencySymbol(source.currency) : ''}${groupAmount(amount)}`)}
									/>
									{#if source}<span class="en-chip">{source.currency}</span>{/if}
								</div>
							</div>
							<span class="en-arrow" aria-hidden="true"><ArrowRight size={20} /></span>
							<div class="en-field">
								<label class="en-label" for="cnv-received">Actually received</label>
								<div class="en-box">
									<input
										id="cnv-received"
										class="en-input big"
										inputmode="decimal"
										autocomplete="off"
										placeholder={destination ? `${currencySymbol(destination)}0.00` : '0.00'}
										bind:value={receivedText}
										onblur={() =>
											received &&
											(receivedText = `${destination ? currencySymbol(destination) : ''}${groupAmount(received)}`)}
									/>
									{#if others.length > 1}
										<WheelPicker
											id="cnv-currency"
											class="en-chip"
											fit
											label="Currency received"
											ariaLabel="Currency received"
											options={others.map((c) => ({ value: c, label: c }))}
											value={destination}
											onchange={(c) => (destinationChoice = c as Currency)}
										/>
									{:else if destination}<span class="en-chip">{destination}</span>{/if}
								</div>
							</div>
						</div>

						<div class="en-row">
							<div class="en-field">
								<label class="en-label" for="cnv-provider">Provider</label>
								<div class="en-box">
									<input
										id="cnv-provider"
										class="en-input"
										list="cnv-providers"
										maxlength="100"
										autocomplete="off"
										placeholder="Grey, Wise, a bank…"
										bind:value={provider}
									/>
									<datalist id="cnv-providers">
										<option value="Grey"></option>
										<option value="Wise"></option>
										<option value="Payoneer"></option>
										<option value="Bank"></option>
									</datalist>
								</div>
							</div>
							<div class="en-field">
								<label class="en-label" for="cnv-quoted">Quoted rate</label>
								<div class="en-box">
									<input
										id="cnv-quoted"
										class="en-input"
										inputmode="decimal"
										autocomplete="off"
										placeholder={quote && base
											? `${currencySymbol(quote)}0.00 per ${currencySymbol(base)}1`
											: 'Optional'}
										bind:value={quotedText}
										onblur={() =>
											quoted && quote && base && (quotedText = formatRate(quoted, quote, base))}
									/>
								</div>
							</div>
							<div class="en-field">
								<label class="en-label" for="cnv-at">Converted at</label>
								<div class="en-box">
									<input
										id="cnv-at"
										class="en-input"
										type="datetime-local"
										max={localNow()}
										bind:value={convertedAt}
									/>
								</div>
							</div>
						</div>

						<EvidencePicker
							{evidence}
							label="Evidence of the conversion"
							addTitle="Upload the conversion receipt"
						/>

						<!-- Mobile summary (B08). -->
						{#if source && destination}
							<div class="en-mobile-sum en-mobile-only">
								<div>
									<span class="en-hint">From {source.pocket} · {source.currency}</span>
									<strong>{amount ? money(amount, source.currency) : '—'}</strong>
								</div>
								<div>
									<span class="en-hint">Actually received in {source.pocket} · {destination}</span>
									<strong class="credit">{received ? money(received, destination) : '—'}</strong>
								</div>
								{#if rate && quote && base}
									<div>
										<span class="en-hint">Effective rate</span>
										<span>{formatRate(rate, quote, base)}</span>
									</div>
								{/if}
							</div>
						{/if}
						<button
							type="submit"
							class="en-primary en-mobile-only"
							disabled={!shell.canAct || shell.paused('conversion') || busy}
							>{busy ? 'Sending…' : 'Submit for review'}</button
						>
					{/if}
				</div>

				<aside class="en-side en-desktop-only" aria-label="What changes">
					<div class="en-summary">
						<div class="en-sum-block">
							<span class="en-kicker"
								>{source ? `${first}’s ${source.pocket} pocket` : 'Choose a pocket'}</span
							>
							{#if source}
								<div class="en-line lg">
									<span>{source.currency}</span>
									<span class="v big">{amount ? `−${money(amount, source.currency)}` : '—'}</span>
								</div>
							{/if}
							{#if destination}
								<div class="en-line lg">
									<span>{destination}</span>
									<span class="v big credit"
										>{received ? `+${money(received, destination)}` : '—'}</span
									>
								</div>
							{/if}
						</div>
						<div class="en-sum-block">
							<div class="en-line">
								<span>Effective rate</span>
								<span class="v">{rate && quote && base ? formatRate(rate, quote, base) : '—'}</span>
							</div>
							<div class="en-line">
								<span>Quoted rate</span>
								<span class="v"
									>{quoted && quote && base ? formatRate(quoted, quote, base) : '—'}</span
								>
							</div>
							{#if difference && quote && !isZero(difference)}
								<div class="en-line">
									<span
										>{difference.startsWith('-')
											? 'Better than the quote'
											: 'Difference from quote'}</span
									>
									<span class="v" class:warn={!difference.startsWith('-')}
										>{money(difference.replace('-', ''), quote)}</span
									>
								</div>
							{/if}
						</div>
						<div class="en-sum-block">
							<button
								type="submit"
								class="en-primary"
								disabled={!shell.canAct || shell.paused('conversion') || busy}
								>{busy ? 'Sending…' : 'Submit for review'}</button
							>
						</div>
					</div>
					<div class="en-art en-desktop-only" aria-hidden="true">
						<div class="en-art-shade"></div>
						<div class="en-art-grain"></div>
						<RootImage pose="convert" class="en-art-root" sizes="160px" />
					</div>
				</aside>
			</form>
		{/if}
	</div>
{/if}

<RootDialog
	bind:open={pinOpen}
	pose="convert"
	title="Confirm with your PIN"
	summary={source && amount && received && destination
		? `${money(amount, source.currency)} → ${money(received, destination)}, sent for review`
		: undefined}
	confirmLabel="Submit for review"
	needsPin
	{pinTry}
	{busy}
	{pinError}
	onConfirm={({ pin }) => submit(pin)}
/>

<style>
	.credit {
		color: var(--color-success);
	}
</style>
