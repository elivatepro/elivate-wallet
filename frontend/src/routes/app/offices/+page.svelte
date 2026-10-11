<!--
	Offices, Paper "App — Screens v2" O01 (desktop) / O03 (mobile) and New
	office O04/O06. Every office visible from the workspace as a tree, with its
	leader, rolled-up member count and money held over its whole subtree in the
	selected currency (W-05; never mixed). "New office" is President Team only;
	a leader is required (by UID).
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext, onMount, untrack } from 'svelte';
	import Building from '@lucide/svelte/icons/building-2';
	import Check from '@lucide/svelte/icons/check';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Plus from '@lucide/svelte/icons/plus';
	import Search from '@lucide/svelte/icons/search';
	import type { OfficeType } from '#lib/contract/common.js';
	import type { Currency } from '#lib/contract/ledger.js';
	import { AppOrgRoutes, OfficesView, type OfficeRow } from '#lib/contract/org-admin.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import { CachedRead } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { formatMoney, hiddenMoney } from '#lib/money.js';
	import {
		initials,
		OFFICE_TYPE_LABELS,
		LEADER_ROLE,
		officeCountLine,
		officeSubline,
		officeTree,
		PARENT_TYPES,
		personName
	} from '#lib/org.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import CurrencySwitch from '#lib/ui/app/CurrencySwitch.svelte';
	import OrgDialog from '#lib/ui/org/OrgDialog.svelte';
	import OrgHero from '#lib/ui/org/OrgHero.svelte';
	import PersonPicker from '#lib/ui/org/PersonPicker.svelte';
	import type { Picked } from '#lib/person-picker.js';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';

	const shell = getContext<Shell>('shell');
	const workspace = $derived(shell.state.kind === 'ready' ? shell.state.view.workspace : null);

	// Blueprint 20 B6: cached first, then fresh; office/member commands clear it.
	const read = new CachedRead<OfficesView>('offices');
	const view = $derived(read.data);
	let loadError = $state<string | null>(null);
	let query = $state('');
	let kind = $state<'all' | OfficeType>('all');
	let currency = $state<Currency>('NGN');
	let notice = $state<string | null>(null);

	async function load() {
		const ticket = read.begin();
		const result = await loadView(AppOrgRoutes.offices, OfficesView);
		if (result.ok) {
			if (!read.fresh(result.value, shell.scope, ticket)) return load();
			loadError = null;
		} else loadError = result.text;
	}

	onMount(() => {
		read.show();
		return read.watch(() => void load());
	});
	// Starts with /api/session, not after it, and again when back online.
	$effect(() => {
		if (shell.readable) untrack(() => void load());
	});
	$effect(() => {
		if (shell.scope) read.confirm(shell.scope);
	});

	const active = $derived((view?.offices ?? []).filter((o) => o.status === 'active'));
	const counts = $derived({
		all: active.length,
		world_team: active.filter((o) => o.type === 'world_team').length,
		director: active.filter((o) => o.type === 'director').length,
		team_leader: active.filter((o) => o.type === 'team_leader').length
	});
	const rows = $derived.by(() => {
		const needle = query.trim().toLowerCase();
		return officeTree(active).filter(({ office }) => {
			if (kind !== 'all' && office.type !== kind) return false;
			if (!needle) return true;
			return (
				office.name.toLowerCase().includes(needle) ||
				office.leaders.some((l) => personName(l).toLowerCase().includes(needle))
			);
		});
	});
	const filtering = $derived(kind !== 'all' || query.trim() !== '');

	function held(office: OfficeRow): string {
		const totals = view?.totals[office.id];
		if (!totals) return '—';
		const row = totals.currencies.find((c) => c.currency === currency);
		if (shell.hideAmounts) return hiddenMoney(currency);
		return formatMoney(row?.posted ?? '0.00', currency);
	}

	const leaderLine = (office: OfficeRow) =>
		office.leaders.length === 0
			? 'Waiting for its leader'
			: office.leaders.length === 1
				? personName(office.leaders[0] ?? null)
				: `${personName(office.leaders[0] ?? null)} +${office.leaderCount - 1}`;

	// ── New office (O04/O06) ──
	const create = new OrgCommand();
	let createOpen = $state(false);
	let newName = $state('');
	let newType = $state<OfficeType>('team_leader');
	let newParent = $state('');
	let newLeader = $state<Picked | null>(null);
	const parents = $derived(active.filter((o) => PARENT_TYPES[newType].includes(o.type)));

	$effect(() => {
		if (newParent && !parents.some((o) => o.id === newParent)) newParent = '';
	});

	function openCreate() {
		create.reset('new');
		notice = null;
		createOpen = true;
	}

	function checkCreate(): string | null {
		const name = newName.trim();
		if (name.length < 2 || name.length > 100) return 'Give the office a name (2–100 characters).';
		if (!newLeader) return `Choose the ${ROLE_LABELS[LEADER_ROLE[newType]]}.`;
		return null;
	}

	async function submitCreate({ pin }: { pin: string | undefined }) {
		if (!workspace) return;
		const leader = newLeader;
		if (!leader) return;
		const office = { type: newType, name: newName.trim(), parentOfficeId: newParent || null };
		// Blueprint 27: an email with no account creates the office and invites its leader.
		const ok =
			leader.kind === 'invite'
				? await create.send(
						AppOrgRoutes.officesInvite,
						'POST',
						{ ...office, email: leader.email, ...(pin ? { pin } : {}) },
						workspace.membershipId
					)
				: await create.send(
						AppOrgRoutes.offices,
						'POST',
						{ ...office, leaderUids: [leader.uid], ...(pin ? { pin } : {}) },
						workspace.membershipId
					);
		if (ok) {
			createOpen = false;
			notice =
				leader.kind === 'invite'
					? `${office.name} created. ${leader.email} was invited to lead it.`
					: `${office.name} created.`;
			newName = '';
			newLeader = null;
			await load();
		}
	}

	const TABS = [
		{ value: 'all', label: 'All' },
		{ value: 'world_team', label: 'World Team' },
		{ value: 'director', label: 'Directorate' },
		{ value: 'team_leader', label: 'Team office' }
	] as const;
</script>

<svelte:head><title>Offices · Elivate Wallet</title></svelte:head>

<div class="o-page">
	<OrgHero
		id="offices-heading"
		pose="offices"
		title={view ? `${counts.all} ${counts.all === 1 ? 'office' : 'offices'}` : 'Offices'}
		line={view ? officeCountLine(active) : null}
	>
		{#snippet actions()}
			{#if view?.canCreate}
				<button type="button" class="hero-cta" disabled={!shell.canAct} onclick={openCreate}>
					<Plus size={18} strokeWidth={2.2} aria-hidden="true" />New office
				</button>
			{/if}
		{/snippet}
	</OrgHero>

	<div class="o-toolbar">
		<label class="o-search o-wide">
			<Search size={16} strokeWidth={2} aria-hidden="true" />
			<span class="visually-hidden">Search offices or leaders</span>
			<input type="search" placeholder="Search offices or leaders" bind:value={query} />
		</label>
		<fieldset class="o-tabs kinds">
			<legend class="visually-hidden">Office kind</legend>
			{#each TABS as tab (tab.value)}
				{#if tab.value === 'all' || counts[tab.value] > 0}
					<label class="o-tab">
						<input type="radio" name="office-kind" value={tab.value} bind:group={kind} />
						<span
							>{tab.label}<span class="o-wide-inline">
								· {counts[tab.value]}</span
							>{#if tab.value === 'all'}<span class="o-narrow-inline">
									· {counts.all}</span
								>{/if}</span
						>
					</label>
				{/if}
			{/each}
		</fieldset>
		<span class="spacer o-wide"></span>
		<span class="o-wide"
			><CurrencySwitch currencies={['NGN', 'USD']} bind:currency size="sm" /></span
		>
	</div>

	{#if notice}
		<p class="o-notice" role="status">
			<Check size={16} strokeWidth={2} aria-hidden="true" />{notice}
		</p>
	{/if}

	<CacheNote savedAt={read.savedAt} online={shell.online} failed={loadError !== null} />
	{#if !view && (!loadError || shell.state.kind === 'loading')}
		<div class="o-skeleton" aria-hidden="true"></div>
		<p class="visually-hidden" role="status">Loading offices</p>
	{:else if loadError && !view}
		<div class="o-error" role="alert">
			<p>{loadError}</p>
			<button type="button" class="o-ghost" onclick={load}>Try again</button>
		</div>
	{:else if rows.length === 0}
		<p class="o-card o-empty">{filtering ? 'No offices match.' : 'No offices yet.'}</p>
	{:else}
		<section class="o-card" aria-label="Offices">
			<div class="o-cols" aria-hidden="true">
				<span class="o-grow">Office</span>
				<span class="c-leader">Leader</span>
				<span class="c-members">Members</span>
				<span class="c-held">Held · {currency}</span>
				<span class="c-chev"></span>
			</div>
			<ul class="o-rows">
				{#each rows as { office, depth } (office.id)}
					<li>
						<a
							class="o-row office"
							href={`/app/offices/${office.id}`}
							style:--depth={filtering ? 0 : depth}
						>
							<span class="o-grow cell">
								<span class="o-icon-tile" class:top={depth === 0 && !filtering} aria-hidden="true"
									><Building size={16} strokeWidth={1.5} /></span
								>
								<span class="o-stack">
									<span class="o-title">{office.name}</span>
									<span class="o-sub o-wide">{officeSubline(office, active)}</span>
									<span class="o-sub o-narrow"
										>{leaderLine(office)} · {office.memberCount}
										{office.memberCount === 1 ? 'member' : 'members'}</span
									>
								</span>
							</span>
							<span class="c-leader o-wide">
								{#if office.leaders[0]}
									<span class="o-avatar sm" aria-hidden="true">{initials(office.leaders[0])}</span>
								{/if}
								<span class="leader-name">{leaderLine(office)}</span>
							</span>
							<span class="c-members o-num o-wide">{office.memberCount}</span>
							<span class="c-held o-money">{held(office)}</span>
							<span class="c-chev o-wide" aria-hidden="true"
								><ChevronRight size={16} strokeWidth={1.5} /></span
							>
						</a>
					</li>
				{/each}
			</ul>
		</section>
		{#if view?.truncated}<p class="o-sub">Showing the first 500 offices.</p>{/if}
	{/if}
</div>

<OrgDialog
	bind:open={createOpen}
	pose="office-new"
	title="New office"
	subtitle={workspace ? `Add a branch to ${workspace.tenantName}` : undefined}
	confirmLabel={newLeader?.kind === 'invite' ? 'Create and invite' : 'Create office'}
	needsReason={false}
	busy={create.busy}
	error={create.error}
	pinError={create.pinError}
	validate={checkCreate}
	onConfirm={submitCreate}
>
	<div class="o-field">
		<label for="office-name">Office name</label>
		<input
			id="office-name"
			class="o-input"
			maxlength="100"
			autocomplete="off"
			bind:value={newName}
		/>
	</div>
	<fieldset class="o-field type-field">
		<legend class="o-field-label">Type</legend>
		<div class="o-tabs type-tabs">
			{#each ['world_team', 'director', 'team_leader'] as const as type (type)}
				<label class="o-tab">
					<input type="radio" name="office-type" value={type} bind:group={newType} />
					<span>{OFFICE_TYPE_LABELS[type]}</span>
				</label>
			{/each}
		</div>
	</fieldset>
	<div class="o-field">
		<label for="office-parent">Parent office</label>
		<WheelPicker
			id="office-parent"
			class="o-input"
			label="Parent office"
			searchPlaceholder="Search offices"
			options={[
				{ value: '', label: 'None (top of the network)' },
				...parents.map((parent) => ({ value: parent.id, label: parent.name }))
			]}
			value={newParent}
			onchange={(id) => (newParent = id)}
		/>
	</div>
	<div class="o-field">
		<label for="office-leader">{ROLE_LABELS[LEADER_ROLE[newType]]}</label>
		<PersonPicker
			id="office-leader"
			bind:value={newLeader}
			allowInvite
			networkName={workspace?.tenantName ?? null}
		/>
		{#if newLeader?.kind === 'invite'}
			<p class="invite-note">
				The office is created now and waits for its leader. They get a 7-day link to sign up, and
				become {ROLE_LABELS[LEADER_ROLE[newType]]} when they accept.
			</p>
		{/if}
	</div>
</OrgDialog>

<style>
	.invite-note {
		margin-top: 8px;
		padding: 12px;
		border-radius: var(--radius-12);
		background: var(--color-accent-subtle);
		color: var(--color-text);
		font-size: 13px;
		line-height: 18px;
	}

	.kinds {
		flex: 1 1 100%;
	}

	.spacer {
		flex: 1;
	}

	.o-wide-inline {
		display: none;
	}

	.office {
		min-height: 64px;
	}

	.cell {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	.cell .o-icon-tile {
		display: none;
	}

	.c-held {
		flex-shrink: 0;
	}

	.type-field {
		margin: 0;
		padding: 0;
		border: 0;
	}

	.type-tabs .o-tab {
		flex: 1;
		height: 40px;
		font-size: var(--text-14);
	}

	@media (min-width: 1024px) {
		.kinds {
			flex: 0 0 auto;
		}

		.o-wide-inline {
			display: inline;
		}

		.o-narrow-inline {
			display: none;
		}

		.office {
			height: 60px;
			min-height: 0;
		}

		.cell {
			padding-left: calc(var(--depth) * 28px);
		}

		.cell .o-icon-tile {
			display: flex;
		}

		.c-leader {
			align-items: center;
			gap: 8px;
			flex-shrink: 0;
			width: 200px;
			min-width: 0;
		}

		.leader-name {
			overflow: hidden;
			color: var(--o-strong);
			font-size: 13px;
			line-height: 16px;
			text-overflow: ellipsis;
			white-space: nowrap;
		}

		.c-members {
			justify-content: flex-end;
			flex-shrink: 0;
			width: 90px;
		}

		.c-held {
			display: flex;
			justify-content: flex-end;
			width: 180px;
		}

		.o-cols .c-members,
		.o-cols .c-held {
			text-align: right;
		}

		.c-chev {
			justify-content: center;
			flex-shrink: 0;
			width: 24px;
			color: var(--o-faint);
		}
	}
</style>
