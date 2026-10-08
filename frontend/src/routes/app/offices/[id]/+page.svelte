<!--
	Office detail, Paper "App — Screens v2" O07 (desktop) / O09 (mobile), with
	Rename O10/O11 and Change leader O12/O13. Money held for members is the
	office plus everything below it, one figure per currency (W-05). Changing a
	leader replaces them (the outgoing leadership ends; reason + PIN).
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import Check from '@lucide/svelte/icons/check';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import { UID_PATTERN } from '#lib/contract/common.js';
	import type { Currency } from '#lib/contract/ledger.js';
	import { AppOrgRoutes, OfficeView } from '#lib/contract/org-admin.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { formatMoney, hiddenMoney } from '#lib/money.js';
	import {
		initials,
		LEADER_ROLE,
		OFFICE_TYPE_LABELS,
		personName,
		STATUS_LABELS
	} from '#lib/org.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import OrgDialog from '#lib/ui/org/OrgDialog.svelte';
	import OrgHero from '#lib/ui/org/OrgHero.svelte';

	const shell = getContext<Shell>('shell');
	const workspace = $derived(shell.state.kind === 'ready' ? shell.state.view.workspace : null);
	const id = $derived(page.params.id ?? '');

	let view = $state<OfficeView | null>(null);
	let loadError = $state<string | null>(null);
	let loadedFor: string | null = null;
	let notice = $state<string | null>(null);

	async function load() {
		const target = id;
		const result = await loadView(AppOrgRoutes.office(target), OfficeView);
		if (target !== id) return;
		if (result.ok) {
			view = result.value;
			loadError = null;
		} else loadError = result.text;
	}

	$effect(() => {
		if (shell.state.kind === 'ready' && loadedFor !== id) {
			loadedFor = id;
			view = null;
			void load();
		}
	});

	const office = $derived(view?.office ?? null);
	const parentName = $derived(
		office && office.path.length > 1 ? (office.path[office.path.length - 2]?.name ?? null) : null
	);
	const leaderTitle = $derived(office ? ROLE_LABELS[LEADER_ROLE[office.type]] : '');

	function held(currency: Currency): string {
		const row = view?.totals?.currencies.find((c) => c.currency === currency);
		if (!view?.totals) return '—';
		if (shell.hideAmounts) return hiddenMoney(currency);
		return formatMoney(row?.posted ?? '0.00', currency);
	}

	// ── Rename (O10/O11): no reason or PIN (rename_office). ──
	const rename = new OrgCommand();
	let renameOpen = $state(false);
	let newName = $state('');

	function openRename() {
		rename.reset(id);
		newName = office?.name ?? '';
		notice = null;
		renameOpen = true;
	}

	const checkName = () =>
		newName.trim().length < 2 || newName.trim().length > 100
			? 'Give the office a name (2–100 characters).'
			: null;

	async function submitRename() {
		if (!workspace) return;
		if (
			await rename.send(
				AppOrgRoutes.office(id),
				'PATCH',
				{ name: newName.trim() },
				workspace.membershipId
			)
		) {
			renameOpen = false;
			notice = 'Office renamed.';
			await load();
		}
	}

	// ── Change leader (O12/O13): replace one leader with another. ──
	const replace = new OrgCommand();
	let replaceOpen = $state(false);
	let outgoing = $state('');
	let incoming = $state('');

	function openReplace() {
		replace.reset(id);
		outgoing = office?.leaders[0]?.membershipId ?? '';
		incoming = '';
		notice = null;
		replaceOpen = true;
	}

	const checkReplace = () =>
		!outgoing
			? 'Choose the leader to replace.'
			: !UID_PATTERN.test(incoming.trim().toUpperCase())
				? 'Enter the new leader’s UID (EW-…).'
				: null;

	async function submitReplace({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!workspace) return;
		const ok = await replace.send(
			AppOrgRoutes.officeLeaderReplace(id),
			'POST',
			{
				outgoingMembershipId: outgoing,
				incomingUid: incoming.trim().toUpperCase(),
				reason,
				...(pin ? { pin } : {})
			},
			workspace.membershipId
		);
		if (ok) {
			replaceOpen = false;
			notice = 'Leader replaced.';
			await load();
		}
	}

	// ── Close office (N01, owner decision 2026-10-08) ──
	const close = new OrgCommand();
	let closeOpen = $state(false);

	function openClose() {
		close.reset(id);
		notice = null;
		closeOpen = true;
	}

	async function submitClose({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!workspace) return;
		if (
			await close.send(
				AppOrgRoutes.officeClose(id),
				'POST',
				{ reason, ...(pin ? { pin } : {}) },
				workspace.membershipId
			)
		) {
			closeOpen = false;
			notice = 'Office closed.';
			await load();
		}
	}

	// ── Place under another office (N04) ──
	const place = new OrgCommand();
	let placeOpen = $state(false);
	let newParent = $state<string>('');
	const TOP = 'top';

	function openPlace() {
		place.reset(id);
		newParent = '';
		notice = null;
		placeOpen = true;
	}

	async function submitPlace({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!workspace) return;
		if (
			await place.send(
				AppOrgRoutes.officePlace(id),
				'POST',
				{ parentOfficeId: newParent === TOP ? null : newParent, reason, ...(pin ? { pin } : {}) },
				workspace.membershipId
			)
		) {
			placeOpen = false;
			notice = 'Office moved.';
			await load();
		}
	}

	const closedOn = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }).format(
			new Date(iso)
		);
	const closedAt = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit',
			hour12: false
		}).format(new Date(iso));

	const joined = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }).format(
			new Date(iso)
		);
</script>

<svelte:head><title>{office?.name ?? 'Office'} · Elivate Wallet</title></svelte:head>

<div class="o-page">
	<nav class="crumbs o-sub" aria-label="Breadcrumb">
		<a href="/app/offices">Offices</a>
		{#if parentName}<span aria-hidden="true">/</span><span>{parentName}</span>{/if}
	</nav>

	{#if !view && !loadError}
		<div class="o-skeleton" aria-hidden="true"></div>
		<p class="visually-hidden" role="status">Loading the office</p>
	{:else if loadError || !office || !view}
		<div class="o-error" role="alert">
			<p>{loadError ?? 'We couldn’t load this office.'}</p>
			<button type="button" class="o-ghost" onclick={load}>Try again</button>
		</div>
	{:else}
		<OrgHero
			id="office-heading"
			pose={office.status === 'closed' ? 'office-closed' : 'office'}
			title={office.name}
			line={`${OFFICE_TYPE_LABELS[office.type]}${parentName ? ` · ${parentName}` : ''}`}
		>
			{#snippet actions()}
				{#if office.status === 'closed'}
					<span class="hero-chip closed-chip"
						>Closed{office.closure ? ` · ${closedOn(office.closure.at)}` : ''}</span
					>
				{/if}
				{#if office.status === 'active' && office.canLeadAssign && office.leaders.length > 0}
					<button type="button" class="hero-chip" disabled={!shell.canAct} onclick={openReplace}
						>Change leader</button
					>
				{/if}
				{#if office.status === 'active' && office.canManage}
					<button type="button" class="hero-chip" disabled={!shell.canAct} onclick={openRename}
						>Rename</button
					>
				{/if}
				{#if office.status === 'active' && view?.isPresident && view.parents.length + (office.parentOfficeId ? 1 : 0) > 0}
					<button type="button" class="hero-chip" disabled={!shell.canAct} onclick={openPlace}
						>Move office</button
					>
				{/if}
				{#if office.status === 'active' && view?.isPresident}
					<button type="button" class="hero-chip" disabled={!shell.canAct} onclick={openClose}
						>Close office</button
					>
				{/if}
			{/snippet}
		</OrgHero>

		{#if notice}
			<p class="o-notice" role="status">
				<Check size={16} strokeWidth={2} aria-hidden="true" />{notice}
			</p>
		{/if}

		<section class="o-card stats" class:closed={office.status === 'closed'} aria-label="Totals">
			<div class="stat ngn">
				<span class="o-label">Held for members · NGN</span>
				<span class="figure">{held('NGN')}</span>
			</div>
			<div class="stat usd">
				<span class="o-label">Held for members · USD</span>
				<span class="figure">{held('USD')}</span>
			</div>
			{#if office.status === 'active'}<div class="stat count">
					<span class="o-label">Members</span>
					<span class="count-line"
						><span class="figure">{office.memberCount}</span
						>{#if office.pendingInvitations > 0}<span class="o-label"
								>{office.pendingInvitations} invited</span
							>{/if}</span
					>
				</div>{/if}
		</section>

		<div class="lower">
			{#if office.status === 'closed'}
				<section class="o-card o-card-pad why" aria-labelledby="why-heading">
					<h2 class="o-label" id="why-heading">Why it closed</h2>
					{#if office.closure}
						<div class="leader">
							<span class="o-avatar lg coral" aria-hidden="true">{initials(office.closure.by)}</span
							>
							<span class="o-stack">
								<span class="leader-name">{office.closure.reason ?? '—'}</span>
								<span class="o-sub"
									>{personName(office.closure.by)} · {closedAt(office.closure.at)}</span
								>
							</span>
						</div>
					{:else}
						<p class="o-sub">Not recorded.</p>
					{/if}
				</section>
			{:else}
				<section class="o-card members" aria-labelledby="members-heading">
					<header class="o-card-head">
						<h2 id="members-heading">Members</h2>
						<a class="o-link" href={`/app/members?officeId=${office.id}`}
							>See all {office.memberCount}</a
						>
					</header>
					{#if !view.members}
						<p class="o-empty">Members aren’t available here.</p>
					{:else if view.members.items.length === 0}
						<p class="o-empty">No members yet.</p>
					{:else}
						<ul class="o-rows">
							{#each view.members.items.slice(0, 8) as member (member.membershipId)}
								<li>
									<a class="o-row" href={`/app/members/${member.membershipId}`}>
										<span
											class="o-avatar"
											class:coral={member.status === 'active'}
											aria-hidden="true">{initials(member.person)}</span
										>
										<span class="o-stack o-grow">
											<span class="o-title">{personName(member.person)}</span>
											<span class="o-sub"
												>{member.emailMasked ? `${member.emailMasked} · ` : ''}{member.person
													?.uid ?? ''}</span
											>
										</span>
										<span class="c-status o-wide">
											<span class="o-pill" data-status={member.status}
												>{STATUS_LABELS[member.status]}</span
											>
										</span>
										<span class="c-since o-wide o-sub"
											>{ROLE_LABELS[member.role]} · {joined(member.startedAt)}</span
										>
										<span class="o-wide chev" aria-hidden="true"
											><ChevronRight size={16} strokeWidth={1.5} /></span
										>
									</a>
								</li>
							{/each}
						</ul>
					{/if}
				</section>
			{/if}
			<div class="side">
				{#if office.status === 'active'}
					<section class="o-card o-card-pad" aria-labelledby="leader-heading">
						<h2 class="o-label" id="leader-heading">{leaderTitle}</h2>
						{#each office.leaders as leader (leader.membershipId)}
							<a class="leader" href={`/app/members/${leader.membershipId}`}>
								<span class="o-avatar lg coral" aria-hidden="true">{initials(leader.person)}</span>
								<span class="o-stack">
									<span class="leader-name">{personName(leader.person)}</span>
									<span class="o-sub">{leader.person?.uid ?? ''}</span>
								</span>
							</a>
						{:else}
							<p class="o-sub">No active leader.</p>
						{/each}
					</section>
				{/if}

				<section class="o-card o-card-pad network" aria-labelledby="network-heading">
					<h2 class="o-label" id="network-heading">In the network</h2>
					<ol class="path">
						{#each office.path as step, i (step.id)}
							{@const self = step.id === office.id}
							<li class:self style:--indent={`${13 + i * 18}px`}>
								<span class="dot" aria-hidden="true"></span>
								{#if self}<span class="step-name">{step.name}</span><span class="o-sub"
										>{office.status === 'closed' ? 'Closed' : 'This office'}</span
									>
								{:else}<a class="step-name" href={`/app/offices/${step.id}`}>{step.name}</a>{/if}
							</li>
						{/each}
					</ol>
				</section>
			</div>
		</div>
	{/if}
</div>

<OrgDialog
	bind:open={renameOpen}
	pose="office-rename"
	title="Rename office"
	subtitle={office ? `${OFFICE_TYPE_LABELS[office.type]} · ${office.name}` : undefined}
	confirmLabel="Save name"
	needsReason={false}
	needsPin={false}
	busy={rename.busy}
	error={rename.error}
	validate={checkName}
	onConfirm={submitRename}
>
	<div class="o-field">
		<label for="rename-name">Office name</label>
		<input
			id="rename-name"
			class="o-input"
			maxlength="100"
			autocomplete="off"
			bind:value={newName}
		/>
	</div>
</OrgDialog>

<OrgDialog
	bind:open={replaceOpen}
	pose="office-leader"
	title="Change leader"
	subtitle={office ? `${office.name} · the current leader is replaced` : undefined}
	confirmLabel="Replace leader"
	mobileConfirmLabel="Replace"
	busy={replace.busy}
	error={replace.error}
	pinError={replace.pinError}
	validate={checkReplace}
	onConfirm={submitReplace}
>
	{#if office && office.leaders.length > 1}
		<div class="o-field">
			<label for="replace-outgoing">Leader to replace</label>
			<select id="replace-outgoing" class="o-input" bind:value={outgoing}>
				{#each office.leaders as leader (leader.membershipId)}
					<option value={leader.membershipId}>{personName(leader.person)}</option>
				{/each}
			</select>
		</div>
	{:else if office?.leaders[0]}
		<div class="o-field">
			<span class="o-field-label">Current leader</span>
			<p class="current">
				<span class="o-avatar sm" aria-hidden="true">{initials(office.leaders[0].person)}</span>
				{personName(office.leaders[0].person)}
				<span class="o-pill replaced">Replaced</span>
			</p>
		</div>
	{/if}
	<div class="o-field">
		<label for="replace-incoming">New {leaderTitle} UID</label>
		<input
			id="replace-incoming"
			class="o-input o-mono"
			placeholder="EW-00000"
			autocomplete="off"
			autocapitalize="characters"
			bind:value={incoming}
		/>
	</div>
</OrgDialog>

<OrgDialog
	bind:open={closeOpen}
	pose="office-close"
	title={office ? `Close ${office.name}` : 'Close office'}
	subtitle="Its money history stays visible to leaders above"
	confirmLabel="Close office"
	tone="danger"
	busy={close.busy}
	error={close.error}
	pinError={close.pinError}
	onConfirm={submitClose}
/>

<OrgDialog
	bind:open={placeOpen}
	pose="office-place"
	title="Place under another office"
	subtitle={office ? `Everything below ${office.name} moves with it` : undefined}
	confirmLabel="Move office"
	mobileConfirmLabel="Move"
	busy={place.busy}
	error={place.error}
	pinError={place.pinError}
	validate={() => (newParent ? null : 'Choose the new place.')}
	onConfirm={submitPlace}
>
	<div class="o-field">
		<span class="o-field-label">Currently under</span>
		<div class="place-row current-place">
			<span class="o-avatar sm" aria-hidden="true"
				>{(parentName ?? 'Top').slice(0, 2).toUpperCase()}</span
			>
			<span class="o-stack o-grow">
				<span class="o-title">{parentName ?? 'Top of the network'}</span>
				{#if office && office.path.length > 1}<span class="o-sub"
						>{OFFICE_TYPE_LABELS[office.path[office.path.length - 2]?.type ?? 'world_team']}</span
					>{/if}
			</span>
			<span class="o-pill current-tag">Current</span>
		</div>
	</div>
	<fieldset class="o-field bare">
		<legend class="o-field-label">New place</legend>
		{#each view?.parents.filter((p) => p.id !== office?.parentOfficeId) ?? [] as option (option.id)}
			<label class="place-row choice">
				<span class="o-avatar sm" aria-hidden="true">{option.name.slice(0, 2).toUpperCase()}</span>
				<span class="o-stack o-grow">
					<span class="o-title">{option.name}</span>
					<span class="o-sub"
						>{OFFICE_TYPE_LABELS[option.type]}{option.parentName
							? ` · under ${option.parentName}`
							: ''}</span
					>
				</span>
				<input type="radio" name="place" value={option.id} bind:group={newParent} />
			</label>
		{/each}
		{#if office?.parentOfficeId}
			<label class="place-row choice">
				<span class="o-avatar sm" aria-hidden="true">↑</span>
				<span class="o-stack o-grow">
					<span class="o-title">Top of the network</span>
					<span class="o-sub">No office above it</span>
				</span>
				<input type="radio" name="place" value={TOP} bind:group={newParent} />
			</label>
		{/if}
	</fieldset>
</OrgDialog>

<style>
	.closed-chip {
		cursor: default;
	}

	.why {
		flex: 1;
	}

	.place-row {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 56px;
		padding: 8px 14px;
		border: 1px solid var(--color-border);
		border-radius: 12px;
	}

	.choice {
		border-color: transparent;
		cursor: pointer;
	}

	.choice:has(input:checked) {
		border-color: var(--color-border);
		background: var(--o-raised);
	}

	.choice input {
		width: 20px;
		height: 20px;
		accent-color: var(--color-accent);
	}

	.current-tag {
		background: var(--o-raised);
		color: var(--o-strong);
	}

	.bare {
		margin: 0;
		padding: 0;
		border: 0;
	}

	@media (min-width: 1024px) {
		.stats.closed .stat.usd {
			border-right: 0;
		}
	}

	.crumbs {
		display: flex;
		gap: 8px;
		font-size: var(--text-14);
	}

	.crumbs a {
		color: var(--color-muted);
		text-decoration: none;
	}

	.stats {
		display: grid;
		grid-template-columns: 1fr 1fr;
	}

	.stat {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 16px 18px;
		min-width: 0;
	}

	.stat.count {
		grid-column: 1 / -1;
		border-top: 1px solid var(--o-row);
	}

	.stat.ngn {
		border-right: 1px solid var(--o-row);
	}

	.figure {
		overflow-wrap: anywhere;
		font-size: 20px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.01em;
		line-height: 26px;
		font-variant-numeric: tabular-nums;
	}

	.count-line {
		display: flex;
		align-items: baseline;
		gap: 8px;
	}

	.lower {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.side {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	h2 {
		font: inherit;
	}

	.leader {
		display: flex;
		align-items: center;
		gap: 12px;
		color: inherit;
		text-decoration: none;
	}

	.leader-name {
		font-size: var(--text-16);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	.path {
		display: flex;
		flex-direction: column;
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.path li {
		display: flex;
		align-items: center;
		gap: 10px;
		height: 36px;
		padding-left: var(--indent);
		color: var(--o-strong);
		font-size: var(--text-14);
		line-height: 18px;
	}

	.path li.self {
		height: 40px;
		padding-right: 12px;
		padding-left: calc(var(--indent) - 1px);
		border: 1px solid var(--color-border);
		border-radius: 10px;
		background: var(--o-raised);
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.dot {
		flex-shrink: 0;
		width: 8px;
		height: 8px;
		border-radius: var(--radius-pill);
		background: #4a5153;
	}

	.self .dot {
		background: var(--color-accent);
	}

	.step-name {
		flex: 1;
		min-width: 0;
		color: inherit;
		text-decoration: none;
	}

	.current {
		display: flex;
		align-items: center;
		gap: 10px;
		font-size: 15px;
	}

	.replaced {
		margin-left: auto;
		background: color-mix(in oklab, var(--color-warning) 16%, transparent);
		color: var(--color-warning);
	}

	select.o-input {
		appearance: auto;
	}

	@media (min-width: 1024px) {
		.stats {
			display: flex;
		}

		.stat {
			padding: 20px 24px;
		}

		.stat.ngn {
			flex: 1.3;
		}

		.stat.usd {
			flex: 1;
			border-right: 1px solid var(--o-row);
		}

		.stat.count {
			flex: 0.8;
			border-top: 0;
		}

		.figure {
			font-size: 26px;
			line-height: 32px;
		}

		.lower {
			flex-direction: row;
			align-items: flex-start;
		}

		.members {
			flex: 1;
		}

		.side {
			flex-shrink: 0;
			width: 380px;
		}

		.members .o-row {
			height: 64px;
		}

		.c-status {
			flex-shrink: 0;
			width: 110px;
		}

		.c-since {
			flex-shrink: 0;
			width: 200px;
			color: var(--o-strong);
			font-size: 13px;
		}

		.chev {
			color: var(--o-faint);
		}
	}
</style>
