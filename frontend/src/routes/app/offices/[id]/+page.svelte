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
			pose="office"
			title={office.name}
			line={`${OFFICE_TYPE_LABELS[office.type]}${parentName ? ` · ${parentName}` : ''}${office.status === 'closed' ? ' · Closed' : ''}`}
		>
			{#snippet actions()}
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
				{#if office.status === 'active' && view?.isPresident}
					<a class="hero-chip" href={`/app/offices/${office.id}/close`}>Close office</a>
				{/if}
			{/snippet}
		</OrgHero>

		{#if notice}
			<p class="o-notice" role="status">
				<Check size={16} strokeWidth={2} aria-hidden="true" />{notice}
			</p>
		{/if}

		<section class="o-card stats" aria-label="Totals">
			<div class="stat ngn">
				<span class="o-label">Held for members · NGN</span>
				<span class="figure">{held('NGN')}</span>
			</div>
			<div class="stat usd">
				<span class="o-label">Held for members · USD</span>
				<span class="figure">{held('USD')}</span>
			</div>
			<div class="stat count">
				<span class="o-label">Members</span>
				<span class="count-line"
					><span class="figure">{office.memberCount}</span>{#if office.pendingInvitations > 0}<span
							class="o-label">{office.pendingInvitations} invited</span
						>{/if}</span
				>
			</div>
		</section>

		<div class="lower">
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
									<span class="o-avatar" class:coral={member.status === 'active'} aria-hidden="true"
										>{initials(member.person)}</span
									>
									<span class="o-stack o-grow">
										<span class="o-title">{personName(member.person)}</span>
										<span class="o-sub"
											>{member.emailMasked ? `${member.emailMasked} · ` : ''}{member.person?.uid ??
												''}</span
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

			<div class="side">
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

				<section class="o-card o-card-pad network" aria-labelledby="network-heading">
					<h2 class="o-label" id="network-heading">In the network</h2>
					<ol class="path">
						{#each office.path as step, i (step.id)}
							{@const self = step.id === office.id}
							<li class:self style:--indent={`${13 + i * 18}px`}>
								<span class="dot" aria-hidden="true"></span>
								{#if self}<span class="step-name">{step.name}</span><span class="o-sub"
										>This office</span
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

<style>
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
