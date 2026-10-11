<!--
	Billing & plan (Blueprint 16, W-19): Paper "App — Screens v4" PL04 (trial),
	PL08d (active: Renewal card, Upgrade), PL07d (paused: pay to resume), PL05
	(upgrade dialog, also opened from the seat cap with ?upgrade), PL09d (manage
	renewal) and "App — Screens v2" B01/B02 (change Billing Owner + PIN).
	Visible to manage_subscription holders and the Billing Owner; the backend
	decides every read and command. Paying always goes through Paystack's page
	and is confirmed server-side (never by the redirect back).
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import {
		BillingOverview,
		OwnerCandidates,
		type OwnerCandidate,
		type Payment,
		type PlanOffer
	} from '#lib/contract/billing.js';
	import {
		canPayYear,
		dateLabel,
		dayLabel,
		daysLeftLabel,
		lastDayLabel,
		naira,
		periodLabel,
		seatsLeftLabel,
		statusChip,
		upgradeFacts,
		yearOffer
	} from '#lib/billing.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import { cachedPage } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import { initials, personName } from '#lib/org.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import OrgDialog from '#lib/ui/org/OrgDialog.svelte';
	import OrgHero from '#lib/ui/org/OrgHero.svelte';

	const shell = getContext<Shell>('shell');
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);

	/**
	 * Blueprint 23: kept without the Paystack checkout links: a key named
	 * `authorization…` is never kept on the device, so it is left out (not
	 * nulled). This page never shows them.
	 */
	const withoutLink = (payment: Payment): Payment => {
		const kept: Partial<Payment> = { ...payment };
		Reflect.deleteProperty(kept, 'authorizationUrl');
		return kept as Payment;
	};
	const withoutCheckout = (overview: BillingOverview): BillingOverview => ({
		...overview,
		payments: overview.payments.map(withoutLink)
	});

	// Blueprint 23: the plan opens from cache (kind 'billing'), then refreshes.
	const read = cachedPage(shell, {
		kind: 'billing',
		load: () => loadView('/api/billing', BillingOverview),
		keep: withoutCheckout
	});
	const view = $derived(read.data);
	const loadError = $derived(read.error);
	const load = () => read.reload();
	// Someone who no longer holds billing access stops seeing the cached plan.
	$effect(() => {
		if (read.errorStatus === 403 || read.errorStatus === 404) read.clear();
	});

	// ?upgrade (from the seat cap) opens the upgrade dialog once the fresh plan is in.
	let upgradeChecked = false;
	$effect(() => {
		if (upgradeChecked || !read.fresh || !read.data) return;
		upgradeChecked = true;
		if (page.url.searchParams.has('upgrade')) openUpgrade(null, true);
	});

	// ── Paying ──────────────────────────────────────────────────────────────

	const pay = new OrgCommand();

	async function checkout(planKey: string, kind: 'year' | 'upgrade') {
		if (!workspaceId) return;
		const result = await pay.send('/api/billing/checkout', 'POST', { planKey, kind }, workspaceId);
		if (!result) return;
		if (result.applied === true) {
			upgradeOpen = false;
			await load();
			return;
		}
		if (typeof result.authorizationUrl === 'string') {
			window.location.assign(result.authorizationUrl);
			return;
		}
		if (typeof result.paymentId === 'string')
			await goto(`/app/billing/payments/${result.paymentId}`);
	}

	// ── Upgrade (PL05) ──────────────────────────────────────────────────────

	let upgradeOpen = $state(false);
	let upgradeKey = $state<string | null>(null);
	let atCap = $state(false);
	const facts = $derived(view ? upgradeFacts(view, upgradeKey ?? undefined) : null);

	function openUpgrade(key: string | null, fromCap = false) {
		upgradeKey = key;
		atCap = fromCap || (!!view && view.seats.cap !== null && view.seats.used >= view.seats.cap);
		pay.reset(`upgrade:${key}`);
		upgradeOpen = true;
	}

	function rowAction(offer: PlanOffer) {
		if (!view) return;
		if (offer.action === 'upgrade' || (view.status === 'trial' && offer.action === 'choose')) {
			openUpgrade(offer.key);
		} else if (offer.action === 'choose') {
			void checkout(offer.key, 'year');
		}
	}

	const rowLabel = (offer: PlanOffer) =>
		offer.action === 'upgrade' || view?.status === 'trial' ? 'Upgrade' : 'Choose';

	// ── Billing Owner (v2 B01) ──────────────────────────────────────────────

	const owner = new OrgCommand();
	let ownerOpen = $state(false);
	let query = $state('');
	let candidates = $state<readonly OwnerCandidate[]>([]);
	let picked = $state<string | null>(null);
	let searchTimer: ReturnType<typeof setTimeout> | undefined;

	async function search() {
		const result = await loadView(
			`/api/billing/owner${query.trim() ? `?q=${encodeURIComponent(query.trim())}` : ''}`,
			OwnerCandidates
		);
		if (result.ok) candidates = result.value.candidates.filter((c) => !c.current);
	}

	function openOwner() {
		owner.reset('owner');
		query = '';
		picked = null;
		ownerOpen = true;
		void search();
	}

	const pickedPerson = $derived(candidates.find((c) => c.membershipId === picked) ?? null);
	const firstName = (c: OwnerCandidate | null) => c?.name?.split(' ')[0] ?? c?.uid ?? 'them';

	async function changeOwner(input: { pin: string | undefined }) {
		if (!workspaceId || !picked) return;
		const result = await owner.send(
			'/api/billing/owner',
			'POST',
			{ membershipId: picked, ...(input.pin ? { pin: input.pin } : {}) },
			workspaceId
		);
		if (result) {
			ownerOpen = false;
			await load();
		}
	}

	// ── Renewal (PL09d) ─────────────────────────────────────────────────────

	const renewal = new OrgCommand();
	let renewalOpen = $state(false);
	let nextKey = $state<string>('');
	// Plans come in band order: the current band and the smaller ones.
	const smaller = $derived(
		view ? view.plans.slice(0, view.plans.findIndex((p) => p.key === view!.plan.key) + 1) : []
	);

	function openRenewal() {
		if (!view) return;
		renewal.reset('renewal');
		nextKey = view.nextPlan?.key ?? view.plan.key;
		renewalOpen = true;
	}

	async function saveRenewal() {
		if (!workspaceId || !view) return;
		const wanted = nextKey === view.plan.key ? null : nextKey;
		if (wanted !== (view.nextPlan?.key ?? null)) {
			const ok = await renewal.send(
				'/api/billing/next-plan',
				'POST',
				{ planKey: wanted },
				workspaceId
			);
			if (!ok) return;
		}
		renewalOpen = false;
		await load();
	}

	async function toggleAutoRenew() {
		if (!workspaceId || !view) return;
		const ok = await renewal.send(
			'/api/billing/auto-renew',
			'POST',
			{ enabled: !view.autoRenew },
			workspaceId
		);
		if (ok) {
			renewalOpen = false;
			await load();
		}
	}

	const nextCharge = $derived.by(() => {
		if (!view?.periodEnd) return '';
		const plan = view.nextPlan ?? view.plan;
		return `${lastDayLabel(new Date(Date.parse(view.periodEnd) - 86_400_000).toISOString())} · ${naira(plan.price)}`;
	});

	const chip = $derived(view ? statusChip(view) : null);
	const heroTitle = $derived.by(() => {
		if (!view) return '';
		if (view.status === 'trial') return daysLeftLabel(view.daysLeft);
		if (view.status === 'paused') return 'Paused';
		if (view.kind === 'development') return 'Development network';
		return `${naira(view.plan.price)} / year`;
	});
	const heroLine = $derived.by(() => {
		if (!view) return '';
		switch (view.status) {
			case 'trial':
				return `Trial ends ${lastDayLabel(view.periodEnd)}, then ${naira(view.plan.price)} a year`;
			case 'paused':
				return `Since ${dayLabel(view.pausedAt)}. History stays available; money can’t move until you pay.`;
			case 'pending':
				return `Pay to open ${view.network}.`;
		}
		if (view.kind === 'development') return 'No end date and no seat limit.';
		if (view.kind === 'complimentary') return `Free until ${lastDayLabel(view.periodEnd)}`;
		return `Current period ${periodLabel(view.periodStart, view.periodEnd)}`;
	});
	const payOffer = $derived(view ? yearOffer(view) : undefined);
	const seatShare = $derived(
		view && view.seats.cap ? Math.min(100, (view.seats.used / view.seats.cap) * 100) : 0
	);
	const paidKind = $derived(view?.kind === 'paid' && view.status !== 'pending');
</script>

<svelte:head><title>Billing · Elivate Wallet</title></svelte:head>

<div class="o-page billing">
	<CacheNote savedAt={read.savedAt} online={shell.online} failed={read.error !== null} />
	{#if loadError && !view}
		<div class="o-error" role="alert">
			<p>{loadError}</p>
			<button type="button" class="o-ghost" onclick={() => load()}>Try again</button>
		</div>
	{:else if !view}
		<div class="o-skeleton" aria-hidden="true"></div>
	{:else}
		<OrgHero
			id="billing-title"
			pose={view.status === 'paused' ? 'dialog-sign-out' : 'income-abacus'}
			title={heroTitle}
			line={heroLine}
		>
			{#snippet eyebrow()}
				<span class="chip" data-tone={chip?.tone}>{chip?.label}</span>
				<span>{view?.plan.name} · yearly</span>
			{/snippet}
		</OrgHero>

		{#if pay.error && !upgradeOpen}<p class="o-notice bad" role="alert">{pay.error}</p>{/if}

		<div class="cards">
			<section class="o-card card" aria-labelledby="seats-label">
				<h2 class="eyebrow" id="seats-label">Seats</h2>
				<p class="big">
					<span class="num">{view.seats.used.toLocaleString('en-GB')}</span>
					{#if view.seats.cap !== null}<span class="of"
							>of {view.seats.cap.toLocaleString('en-GB')} people</span
						>{:else}<span class="of">people</span>{/if}
				</p>
				{#if view.seats.cap !== null}
					<div class="bar" aria-hidden="true"><span style:width={`${seatShare}%`}></span></div>
				{/if}
				<p class="muted">{seatsLeftLabel(view.seats.used, view.seats.cap)}</p>
			</section>

			<section class="o-card card" aria-labelledby="owner-label">
				<h2 class="eyebrow" id="owner-label">Billing owner</h2>
				<div class="owner">
					<span class="o-avatar coral" aria-hidden="true">{initials(view.owner)}</span>
					<span class="owner-text">
						<span class="owner-name">{view.owner ? personName(view.owner) : 'Not set'}</span>
						{#if view.owner?.role}<span class="muted"
								>{view.owner.role === 'president_team_member'
									? 'President'
									: ROLE_LABELS[view.owner.role]}</span
							>{/if}
					</span>
					{#if view.canManage}
						<button type="button" class="small-ghost" onclick={openOwner}>Change</button>
					{/if}
				</div>
			</section>

			{#if paidKind}
				<section class="o-card card" aria-labelledby="renewal-label">
					<h2 class="eyebrow" id="renewal-label">Renewal</h2>
					<p class="value">
						{#if view.status === 'paused'}Not renewed
						{:else if view.renewsAutomatically}Auto-renews {lastDayLabel(view.periodEnd)}
						{:else}Renews by payment{/if}
					</p>
					{#if view.canManage && view.status === 'active'}
						<button type="button" class="o-link start" onclick={openRenewal}>Manage renewal</button>
					{/if}
				</section>
			{:else}
				<section class="o-card card" aria-labelledby="extras-label">
					<h2 class="eyebrow" id="extras-label">Extras</h2>
					<p class="value">None active</p>
					<p class="muted">Ask about extras through Support.</p>
				</section>
			{/if}
		</div>

		<div class="lower">
			<section class="o-card plans" aria-labelledby="plans-label">
				<div class="head">
					<h2 id="plans-label">Plans</h2>
					<span class="muted">Billed yearly in NGN · VAT included</span>
				</div>
				<ul class="rows">
					{#each view.plans as offer (offer.key)}
						<li class="plan-row" class:current={offer.action === 'current'}>
							<span class="plan-text">
								<span class="plan-name">{offer.name}</span>
								<span class="plan-price">{naira(offer.price)}</span>
							</span>
							<span class="plan-action">
								{#if offer.action === 'current'}
									<span class="current-chip">Current</span>
								{:else if offer.action}
									<button
										type="button"
										class="small-ghost"
										disabled={pay.busy || !offer.fits}
										title={offer.fits
											? undefined
											: 'Your network has more people than this plan covers'}
										onclick={() => rowAction(offer)}>{rowLabel(offer)}</button
									>
								{/if}
							</span>
						</li>
					{/each}
				</ul>
			</section>

			<section class="o-card payments" aria-labelledby="payments-label">
				<div class="head"><h2 id="payments-label">Payments</h2></div>
				{#if view.payments.length > 0}
					<ul class="rows">
						{#each view.payments as payment (payment.id)}
							<li class="pay-row">
								<span class="pay-text">
									<span class="pay-amount">{naira(payment.amount)}</span>
									<span class="muted"
										>{dayLabel(payment.paidAt ?? payment.createdAt)} · Paystack</span
									>
								</span>
								<span class="pay-pill" data-status={payment.status}
									>{payment.status === 'paid' ? 'Paid' : 'Not paid'}</span
								>
								<a class="o-link" href={`/app/billing/payments/${payment.id}`}>Receipt</a>
							</li>
						{/each}
					</ul>
				{/if}
				{#if payOffer && canPayYear(view)}
					<div class="pay-block">
						<div class="pay-copy">
							{#if view.status === 'paused'}
								<p class="pay-title">Pay to resume</p>
								<p class="muted">A new year starts the day your payment is confirmed.</p>
							{:else if view.status === 'trial'}
								<p class="pay-title">
									{view.payments.length ? 'Pay for your year' : 'No payments yet'}
								</p>
								<p class="muted">Pay any time before {lastDayLabel(view.periodEnd)}.</p>
							{:else if view.status === 'pending'}
								<p class="pay-title">No payments yet</p>
								<p class="muted">Pay to open {view.network}.</p>
							{:else}
								<p class="pay-title">Renew your plan</p>
								<p class="muted">
									{view.periodEnd
										? `Your next year starts ${dateLabel(view.lastDay)}.`
										: 'Your paid year starts the day you pay.'}
								</p>
							{/if}
						</div>
						<button
							type="button"
							class="o-primary"
							disabled={pay.busy || !shell.canAct}
							aria-busy={pay.busy}
							onclick={() => checkout(payOffer.key, 'year')}>Pay {naira(payOffer.price)}</button
						>
					</div>
				{/if}
			</section>
		</div>
	{/if}
</div>

{#if view && facts}
	<OrgDialog
		bind:open={upgradeOpen}
		pose="upgrade"
		title={atCap ? `${view.network} is full` : 'Move up a plan'}
		subtitle={atCap
			? 'Move up a plan to keep adding people'
			: facts.kind === 'upgrade'
				? 'Pay the difference for the rest of your year'
				: 'Your paid year starts when the trial ends'}
		confirmLabel={`Pay ${naira(facts.amount)}`}
		cancelLabel="Not now"
		needsReason={false}
		needsPin={false}
		busy={pay.busy}
		error={pay.error}
		onConfirm={() => checkout(facts.plan.key, facts.kind)}
	>
		<dl class="facts">
			<div>
				<dt>New plan</dt>
				<dd>{facts.plan.name}</dd>
			</div>
			{#if facts.until}<div>
					<dt>Until</dt>
					<dd>{facts.until}</dd>
				</div>{/if}
			<div>
				<dt>Pay now</dt>
				<dd>{naira(facts.amount)}</dd>
			</div>
		</dl>
	</OrgDialog>
{/if}

{#if view}
	<OrgDialog
		bind:open={ownerOpen}
		pose="dialog-replace"
		title="Change Billing Owner"
		subtitle={`Pick an active member of ${view.network}`}
		confirmLabel={pickedPerson ? `Make ${firstName(pickedPerson)} Billing Owner` : 'Choose someone'}
		mobileConfirmLabel="Make Billing Owner"
		needsReason={false}
		busy={owner.busy}
		error={owner.error}
		pinError={owner.pinError}
		validate={() => (picked ? null : 'Choose who becomes the Billing Owner.')}
		onConfirm={changeOwner}
	>
		<div class="o-search">
			<input
				type="search"
				placeholder="Search name or UID"
				aria-label="Search name or UID"
				bind:value={query}
				oninput={() => {
					clearTimeout(searchTimer);
					searchTimer = setTimeout(search, 250);
				}}
			/>
		</div>
		<div class="candidates" role="radiogroup" aria-label="Members">
			{#each candidates as candidate (candidate.membershipId)}
				<label class="candidate" class:on={picked === candidate.membershipId}>
					<span class="o-avatar sm" aria-hidden="true">{initials(candidate)}</span>
					<span class="cand-text">
						<span class="owner-name">{personName(candidate)}</span>
						<span class="muted"
							>{ROLE_LABELS[candidate.role]}{candidate.office ? ` · ${candidate.office}` : ''}</span
						>
					</span>
					<span class="o-mono uid">{candidate.uid}</span>
					<input type="radio" name="owner" value={candidate.membershipId} bind:group={picked} />
				</label>
			{:else}
				<p class="muted">No one matches.</p>
			{/each}
		</div>
	</OrgDialog>

	<OrgDialog
		bind:open={renewalOpen}
		pose="upgrade"
		title="Renewal"
		subtitle="Your card is charged a day before the year ends"
		confirmLabel="Save"
		needsReason={false}
		needsPin={false}
		busy={renewal.busy}
		error={renewal.error}
		onConfirm={saveRenewal}
	>
		<dl class="facts">
			<div>
				<dt>Auto-renew</dt>
				<dd>{view.renewsAutomatically ? 'On' : view.autoRenew ? 'Needs a card payment' : 'Off'}</dd>
			</div>
			<div>
				<dt>Next charge</dt>
				<dd>{view.renewsAutomatically ? nextCharge : '—'}</dd>
			</div>
			<div>
				<dt><label for="next-plan">Next year’s plan</label></dt>
				<dd>
					<select id="next-plan" class="plan-select" bind:value={nextKey}>
						{#each smaller as option (option.key)}
							<option value={option.key} disabled={!option.fits}>{option.name}</option>
						{/each}
					</select>
				</dd>
			</div>
		</dl>
		{#snippet secondary()}
			<button type="button" class="org-cancel" disabled={renewal.busy} onclick={toggleAutoRenew}
				>{view?.autoRenew ? 'Turn off auto-renew' : 'Turn on auto-renew'}</button
			>
		{/snippet}
	</OrgDialog>
{/if}

<style>
	.billing {
		gap: 24px;
	}

	.chip {
		flex-shrink: 0;
		white-space: nowrap;
		padding: 3px 10px;
		border-radius: var(--radius-pill);
		font-size: var(--text-12);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-16);
	}

	.chip[data-tone='trial'],
	.chip[data-tone='pending'] {
		background: #3a2e1a;
		color: #f2b85e;
	}

	.chip[data-tone='active'] {
		background: #1c3328;
		color: #43c48b;
	}

	.chip[data-tone='paused'] {
		background: #3a2020;
		color: #f57875;
	}

	.cards {
		display: grid;
		gap: 16px;
	}

	.card {
		display: flex;
		flex-direction: column;
		gap: 14px;
		padding: 22px 24px;
		border-radius: 20px;
	}

	.eyebrow {
		margin: 0;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: 400;
		letter-spacing: 0.08em;
		line-height: 14px;
		text-transform: uppercase;
	}

	.big {
		display: flex;
		align-items: baseline;
		gap: 8px;
		margin: 0;
	}

	.num {
		font-size: 32px;
		font-weight: var(--font-weight-semibold);
		line-height: 38px;
		font-variant-numeric: tabular-nums;
	}

	.of {
		color: var(--color-muted);
		font-size: 15px;
		line-height: 18px;
	}

	.bar {
		display: flex;
		height: 6px;
		overflow: hidden;
		border-radius: var(--radius-pill);
		background: var(--o-edge, #2c3133);
	}

	.bar span {
		min-width: 6px;
		border-radius: var(--radius-pill);
		background: var(--color-accent);
	}

	.muted {
		margin: 0;
		color: var(--color-muted);
		font-size: 13px;
		line-height: 16px;
	}

	.value {
		margin: 0;
		font-size: 15px;
		line-height: 18px;
	}

	.start {
		align-self: flex-start;
		padding: 0;
	}

	.owner {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	.owner-text,
	.cand-text,
	.pay-text,
	.pay-copy {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.owner-name {
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.small-ghost {
		display: inline-flex;
		align-items: center;
		height: 34px;
		padding: 0 14px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		cursor: pointer;
	}

	.small-ghost:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	.lower {
		display: grid;
		gap: 16px;
	}

	.plans,
	.payments {
		border-radius: 20px;
	}

	.head {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
		padding: 18px 22px;
		border-bottom: 1px solid var(--o-row, #ffffff0f);
	}

	.head h2 {
		margin: 0;
		font-size: 16px;
		font-weight: var(--font-weight-semibold);
		line-height: 20px;
	}

	.rows {
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.plan-row,
	.pay-row {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 60px;
		padding: 10px 22px;
		border-bottom: 1px solid var(--o-row, #ffffff0a);
	}

	.plan-row:last-child,
	.pay-row:last-child {
		border-bottom: 0;
	}

	.plan-row.current {
		background: var(--color-raised);
	}

	.plan-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.plan-name {
		min-width: 0;
		font-size: 15px;
		line-height: 18px;
	}

	.plan-row.current .plan-name {
		font-weight: var(--font-weight-medium);
	}

	.plan-price {
		color: var(--color-muted);
		font-size: 14px;
		line-height: 18px;
		font-variant-numeric: tabular-nums;
	}

	.plan-action {
		display: flex;
		flex-shrink: 0;
		justify-content: flex-end;
		width: 96px;
	}

	.current-chip {
		padding: 3px 10px;
		border-radius: var(--radius-pill);
		background: var(--color-accent-subtle);
		color: var(--o-coral-text, var(--color-accent-text));
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.pay-amount {
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.pay-pill {
		padding: 3px 10px;
		border-radius: var(--radius-pill);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.pay-pill[data-status='paid'] {
		background: color-mix(in oklab, var(--color-success) 16%, transparent);
		color: var(--color-success);
	}

	.pay-pill:not([data-status='paid']) {
		background: color-mix(in oklab, var(--color-danger) 16%, transparent);
		color: var(--color-danger);
	}

	.pay-block {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 16px;
		padding: 24px 22px;
	}

	.pay-title {
		margin: 0;
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 20px;
	}

	.facts {
		margin: 0;
		overflow: hidden;
		border: 1px solid var(--color-border);
		border-radius: 14px;
	}

	.facts > div {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		min-height: 44px;
		padding: 0 16px;
		border-bottom: 1px solid var(--color-border);
		font-size: var(--text-14);
	}

	.facts > div:last-child {
		border-bottom: 0;
	}

	.facts dt {
		color: var(--color-muted);
	}

	.facts dd {
		margin: 0;
		font-weight: var(--font-weight-medium);
		text-align: right;
		font-variant-numeric: tabular-nums;
	}

	.plan-select {
		height: 32px;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-weight: var(--font-weight-medium);
		text-align: right;
	}

	.candidates {
		display: flex;
		flex-direction: column;
		gap: 6px;
		max-height: 300px;
		overflow-y: auto;
	}

	.candidate {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 10px 14px;
		border: 1px solid transparent;
		border-radius: 14px;
		cursor: pointer;
	}

	.candidate.on {
		border-color: var(--color-border);
		background: var(--color-raised);
	}

	.candidate input {
		width: 20px;
		height: 20px;
		accent-color: var(--color-accent);
	}

	.uid {
		color: var(--color-muted);
		font-size: var(--text-12);
	}

	@media (min-width: 1024px) {
		.cards {
			grid-template-columns: repeat(3, 1fr);
		}

		.lower {
			grid-template-columns: 1.2fr 1fr;
			align-items: start;
		}

		.plan-text {
			flex-direction: row;
			align-items: center;
			gap: 12px;
		}

		.plan-name {
			flex: 1;
		}

		.plan-price {
			flex-shrink: 0;
			width: 150px;
			color: var(--color-text);
			font-size: 15px;
			text-align: right;
		}

		.plan-action {
			width: 120px;
		}
	}
</style>
