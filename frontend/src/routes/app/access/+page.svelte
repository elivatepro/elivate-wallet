<!--
	Roles & access, Paper "App — Screens v2": R01/R02 role permissions (five
	fixed roles; protected rows locked; changes saved together with a reason
	and the PIN), R03/R04 new cross-access rule (specific permissions for one
	person: grant or deny, scope, start, optional expiry, reason) and R05/R06
	evidence reviewers (specific people; never their own operations). The
	cross-access list itself is not drawn yet (minimal list, W-06 field set).
	Conversion and adjustment authority sit in the Money group (owner decision
	2026-10-08) and are switched per role here.
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext, untrack } from 'svelte';
	import { SvelteMap } from 'svelte/reactivity';
	import Ban from '@lucide/svelte/icons/ban';
	import Check from '@lucide/svelte/icons/check';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Lock from '@lucide/svelte/icons/lock';
	import Plus from '@lucide/svelte/icons/plus';
	import Search from '@lucide/svelte/icons/search';
	import X from '@lucide/svelte/icons/x';
	import { UID_PATTERN, type Role } from '#lib/contract/common.js';
	import {
		AccessView,
		AppOrgRoutes,
		MemberRows,
		type AccessAssignment,
		type MemberRow,
		type Reviewer
	} from '#lib/contract/org-admin.js';
	import { newKey } from '#lib/client/api.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import { cachedPage } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import {
		groupPermissions,
		initials,
		PERMISSION_GROUPS,
		PERMISSION_SCOPE,
		permissionLabel,
		personName,
		ROLE_COLUMN,
		ROLE_ORDER
	} from '#lib/org.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import OrgDialog from '#lib/ui/org/OrgDialog.svelte';
	import OrgHero from '#lib/ui/org/OrgHero.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';

	type Tab = 'roles' | 'access' | 'reviewers';

	const shell = getContext<Shell>('shell');
	const workspace = $derived(shell.state.kind === 'ready' ? shell.state.view.workspace : null);

	let tab = $state<Tab>('roles');
	let notice = $state<string | null>(null);
	let started = false;

	// Blueprint 23: roles & access open from cache (kind 'access'), then
	// refresh. The matrix stays read-only while the cached copy shows.
	const access = cachedPage(shell, {
		kind: 'access',
		load: () => loadView(AppOrgRoutes.access, AccessView)
	});
	const view = $derived(access.data);
	const loadError = $derived(view ? null : access.error);
	const load = () => access.reload();
	// No longer allowed to see this: drop the cached copy.
	$effect(() => {
		if (access.errorStatus === 403) access.clear();
	});

	$effect(() => {
		if (started) return;
		started = true;
		const asked = new URL(window.location.href).searchParams.get('tab');
		if (asked === 'access' || asked === 'reviewers') tab = asked;
	});
	$effect(() => {
		const shown = view;
		if (!shown || shown.rolePermissions) return;
		untrack(() => {
			if (tab === 'roles') tab = shown.assignments ? 'access' : 'reviewers';
		});
	});

	const activeAssignments = $derived((view?.assignments?.items ?? []).filter((a) => !a.revokedAt));

	// ── Role permissions (R01/R02) ──
	const pending = new SvelteMap<string, boolean>();
	const cellKey = (role: Role, permission: string) => `${role}:${permission}`;
	const catalogue = $derived.by(() => {
		const rows = view?.rolePermissions ?? [];
		const keys = [...new Set(rows.map((r) => r.permission))];
		return { keys, groups: groupPermissions(keys) };
	});
	const scopeOf: Record<string, string> = {
		view_own_wallet: 'self',
		view_own_financials: 'self',
		export_own_statement: 'self',
		initiate_own_withdrawal: 'self',
		manage_own_payout_accounts: 'self',
		transfer_between_own_pockets: 'self',
		manage_subscription: 'tenant',
		manage_role_permissions: 'tenant',
		manage_security_settings: 'tenant',
		configure_adjustment_evidence_requirement: 'tenant',
		reverse_transaction: 'tenant',
		transfer_presidency: 'tenant',
		deactivate_tenant: 'tenant',
		manage_allocation: 'tenant',
		review_financial_evidence: 'assignment'
	};
	const scopeLabel = (key: string) => PERMISSION_SCOPE[scopeOf[key] ?? 'office'] ?? 'Office';
	function cell(role: Role, permission: string) {
		const row = view?.rolePermissions?.find((r) => r.role === role && r.permission === permission);
		const changed = pending.get(cellKey(role, permission));
		return {
			allowed: changed ?? row?.allowed ?? false,
			editable: !!row?.editable && !!view?.canEditRoles && access.savedAt === null,
			locked: !row?.editable
		};
	}
	function toggle(role: Role, permission: string) {
		const row = view?.rolePermissions?.find((r) => r.role === role && r.permission === permission);
		if (!row) return;
		const key = cellKey(role, permission);
		const next = !(pending.get(key) ?? row.allowed);
		if (next === row.allowed) pending.delete(key);
		else pending.set(key, next);
		notice = null;
	}
	const groupOpen = new SvelteMap<string, boolean>([['Own wallet', false]]);
	const isOpen = (title: string) => groupOpen.get(title) ?? true;
	const groupOn = (keys: readonly string[], role: Role) =>
		keys.filter((k) => cell(role, k).allowed).length;
	const groupLocked = (keys: readonly string[]) =>
		keys.filter((k) => !view?.rolePermissions?.find((r) => r.permission === k)?.editable).length;
	let mobileRole = $state<Role>('team_leader');

	const pendingSummary = $derived.by(() => {
		const first = [...pending.keys()][0];
		if (!first) return '';
		const [role, permission] = first.split(':') as [Role, string];
		return `${ROLE_COLUMN[role]} · ${permissionLabel(permission)}`;
	});

	const save = new OrgCommand();
	let saveOpen = $state(false);
	/** One key per change, kept while the outcome is unknown (W-00). */
	const changeKeys = new SvelteMap<string, string>();

	async function submitSave({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!workspace) return;
		const changes = [...pending.entries()].map(([key, allowed]) => {
			const [role, permission] = key.split(':') as [Role, string];
			// A changed reason is a new request, so it gets new keys (replay stays exact).
			const id = `${key}:${allowed}:${reason}`;
			if (!changeKeys.has(id)) changeKeys.set(id, newKey());
			return { role, permission, allowed, idempotencyKey: changeKeys.get(id)! };
		});
		const ok = await save.send(
			AppOrgRoutes.rolePermissions,
			'PUT',
			{ changes, reason, ...(pin ? { pin } : {}) },
			workspace.membershipId,
			false
		);
		if (ok) {
			saveOpen = false;
			pending.clear();
			changeKeys.clear();
			notice = 'Role permissions saved.';
		}
		await load();
	}

	// ── Cross-access (R03/R04) ──
	const grant = new OrgCommand();
	let grantOpen = $state(false);
	let subjectUid = $state('');
	let grantPermissions = $state<string[]>([]);
	let ruleEffect = $state<'allow' | 'deny'>('allow');
	let scopeType = $state<'tenant' | 'office_subtree' | 'member'>('office_subtree');
	let scopeOffice = $state('');
	let scopeUid = $state('');
	let startsOn = $state('');
	let expiresOn = $state('');
	/** Grantable: editable, office- or tenant-scoped (A-03); the backend re-checks. */
	const grantable = $derived(
		view?.rolePermissions
			? [
					...new Set(view.rolePermissions.filter((r) => r.editable).map((r) => r.permission))
				].filter((k) => scopeOf[k] !== 'self' && scopeOf[k] !== 'assignment')
			: PERMISSION_GROUPS.filter((g) => ['Money', 'Reports', 'People'].includes(g.title)).flatMap(
					(g) => g.keys
				)
	);
	/** What "+ Add" still offers. */
	const addable = $derived(grantable.filter((k) => !grantPermissions.includes(k)));
	const today = () => new Date().toISOString().slice(0, 10);

	function openGrant() {
		grant.reset('grant');
		subjectUid = '';
		grantPermissions = [];
		ruleEffect = 'allow';
		scopeType = 'office_subtree';
		scopeOffice = view?.offices[0]?.id ?? '';
		scopeUid = '';
		startsOn = today();
		expiresOn = '';
		notice = null;
		grantOpen = true;
	}

	function checkGrant(): string | null {
		if (!UID_PATTERN.test(subjectUid.trim().toUpperCase())) return 'Enter the person’s UID (EW-…).';
		if (grantPermissions.length === 0) return 'Add at least one permission.';
		if (scopeType === 'office_subtree' && !scopeOffice) return 'Choose the office.';
		if (scopeType === 'member' && !UID_PATTERN.test(scopeUid.trim().toUpperCase())) {
			return 'Enter the member’s UID (EW-…).';
		}
		if (ruleEffect === 'allow' && expiresOn && expiresOn <= (startsOn || today())) {
			return 'The expiry must come after the start.';
		}
		return null;
	}

	async function submitGrant({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!workspace) return;
		const starts =
			startsOn && startsOn > today() ? new Date(`${startsOn}T00:00:00`).toISOString() : null;
		const expires =
			ruleEffect === 'allow' && expiresOn ? new Date(`${expiresOn}T23:59:59`).toISOString() : null;
		const rules = grantPermissions.map((permission) => ({
			permission,
			effect: ruleEffect,
			scopeType,
			...(scopeType === 'office_subtree' ? { scopeOfficeId: scopeOffice } : {}),
			...(scopeType === 'member' ? { scopeUid: scopeUid.trim().toUpperCase() } : {}),
			...(starts ? { startsAt: starts } : {}),
			...(expires ? { expiresAt: expires } : {})
		}));
		const ok = await grant.send(
			AppOrgRoutes.access,
			'POST',
			{ subjectUid: subjectUid.trim().toUpperCase(), rules, reason, ...(pin ? { pin } : {}) },
			workspace.membershipId
		);
		if (ok) {
			grantOpen = false;
			notice = `Cross-access saved for ${subjectUid.trim().toUpperCase()}.`;
			tab = 'access';
			await load();
		}
	}

	// ── Revoke a cross-access assignment ──
	const revoke = new OrgCommand();
	let revokeTarget = $state<AccessAssignment | null>(null);
	let revokeOpen = $state(false);

	function askRevoke(assignment: AccessAssignment) {
		revoke.reset(assignment.id);
		revokeTarget = assignment;
		notice = null;
		revokeOpen = true;
	}

	async function submitRevoke({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!workspace || !revokeTarget) return;
		if (
			await revoke.send(
				AppOrgRoutes.accessRevoke(revokeTarget.id),
				'POST',
				{ reason, ...(pin ? { pin } : {}) },
				workspace.membershipId
			)
		) {
			revokeOpen = false;
			notice = 'Cross-access revoked.';
			await load();
		}
	}

	const ruleLine = (assignment: AccessAssignment) =>
		assignment.rules
			.map(
				(r) =>
					`${r.effect === 'deny' ? 'Deny' : 'Grant'} ${permissionLabel(r.permission)} · ${
						r.scopeType === 'tenant'
							? 'whole network'
							: r.scopeType === 'office_subtree'
								? (r.scopeOfficeName ?? 'office')
								: personName(r.scopePerson)
					}`
			)
			.join('; ');

	// ── Evidence reviewers (R05/R06) ──
	let reviewerQuery = $state('');
	let reviewerResults = $state<MemberRow[]>([]);
	let reviewerPick = $state<MemberRow | null>(null);
	let searchTimer: ReturnType<typeof setTimeout> | undefined;
	let searchSeq = 0;

	function searchReviewers() {
		reviewerPick = null;
		clearTimeout(searchTimer);
		const q = reviewerQuery.trim();
		if (q.length < 2) {
			reviewerResults = [];
			return;
		}
		searchTimer = setTimeout(async () => {
			const mine = ++searchSeq;
			const result = await loadView(
				`${AppOrgRoutes.members}?status=active&q=${encodeURIComponent(q)}`,
				MemberRows
			);
			if (mine === searchSeq && result.ok) reviewerResults = result.value.items.slice(0, 6);
		}, 250);
	}

	const assign = new OrgCommand();
	let assignOpen = $state(false);

	function openAssign() {
		if (!reviewerPick) return;
		assign.reset(reviewerPick.membershipId);
		notice = null;
		assignOpen = true;
	}

	async function submitAssign({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!workspace || !reviewerPick) return;
		if (
			await assign.send(
				AppOrgRoutes.reviewers,
				'POST',
				{ membershipId: reviewerPick.membershipId, reason, ...(pin ? { pin } : {}) },
				workspace.membershipId
			)
		) {
			assignOpen = false;
			notice = `${personName(reviewerPick.person)} can now review evidence.`;
			reviewerQuery = '';
			reviewerResults = [];
			reviewerPick = null;
			await load();
		}
	}

	const remove = new OrgCommand();
	let removeTarget = $state<Reviewer | null>(null);
	let removeOpen = $state(false);

	function askRemove(reviewer: Reviewer) {
		remove.reset(reviewer.assignmentId);
		removeTarget = reviewer;
		notice = null;
		removeOpen = true;
	}

	async function submitRemove({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!workspace || !removeTarget) return;
		if (
			await remove.send(
				AppOrgRoutes.reviewerEnd(removeTarget.assignmentId),
				'POST',
				{ reason, ...(pin ? { pin } : {}) },
				workspace.membershipId
			)
		) {
			removeOpen = false;
			notice = 'Reviewer removed.';
			await load();
		}
	}

	const date = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }).format(
			new Date(iso)
		);

	const reviewerCount = $derived(view?.reviewers?.length ?? 0);
	const heroTitle = $derived(
		tab === 'reviewers'
			? `${reviewerCount} named ${reviewerCount === 1 ? 'reviewer' : 'reviewers'}`
			: tab === 'access'
				? 'Cross-access'
				: 'Who can do what'
	);
	const heroLine = $derived(
		tab === 'reviewers'
			? 'Only they clear or reject financial evidence'
			: tab === 'access'
				? 'Specific permissions, not a role'
				: '5 fixed roles · locked rows are protected'
	);
</script>

<svelte:head><title>Roles & access · Elivate Wallet</title></svelte:head>

{#snippet toggleCell(role: Role, permission: string)}
	{@const c = cell(role, permission)}
	{#if c.locked}
		<span class="locked" class:on={c.allowed}>
			<Lock size={14} strokeWidth={1.5} aria-hidden="true" />{c.allowed ? 'On' : 'Off'}
		</span>
	{:else}
		<button
			type="button"
			class="switch"
			role="switch"
			aria-checked={c.allowed}
			aria-label={`${permissionLabel(permission)} for ${ROLE_LABELS[role]}`}
			disabled={!c.editable || !shell.canAct}
			onclick={() => toggle(role, permission)}
		>
			<span class="knob"></span>
		</button>
	{/if}
{/snippet}

<div class="o-page">
	<OrgHero
		id="access-heading"
		pose={tab === 'reviewers' ? 'reviewers' : 'roles'}
		title={heroTitle}
		line={heroLine}
	>
		{#snippet actions()}
			{#if tab !== 'reviewers' && view?.canManageAccess}
				<button type="button" class="hero-cta" disabled={!shell.canAct} onclick={openGrant}>
					<Plus size={18} strokeWidth={2.2} aria-hidden="true" />Cross-access rule
				</button>
			{/if}
		{/snippet}
	</OrgHero>

	<div class="o-toolbar">
		<div class="o-tabs" role="group" aria-label="Section">
			{#if view?.rolePermissions}
				<button
					type="button"
					class="o-tab"
					aria-pressed={tab === 'roles'}
					onclick={() => (tab = 'roles')}
					><span class="o-wide">Role permissions</span><span class="o-narrow">Roles</span></button
				>
			{/if}
			{#if view?.assignments}
				<button
					type="button"
					class="o-tab"
					aria-pressed={tab === 'access'}
					onclick={() => (tab = 'access')}
					>Cross-access<span class="o-wide">&nbsp;· {activeAssignments.length}</span></button
				>
			{/if}
			{#if view?.reviewers}
				<button
					type="button"
					class="o-tab"
					aria-pressed={tab === 'reviewers'}
					onclick={() => (tab = 'reviewers')}
					><span class="o-wide">Evidence reviewers&nbsp;· {reviewerCount}</span><span
						class="o-narrow">Reviewers</span
					></button
				>
			{/if}
		</div>
		<span class="spacer o-wide"></span>
		{#if tab === 'reviewers'}
			<span class="legend o-wide"
				><Ban size={14} strokeWidth={1.8} aria-hidden="true" />Never reviews their own</span
			>
		{:else if tab === 'roles'}
			<span class="legend o-wide"
				><Lock size={13} strokeWidth={1.8} aria-hidden="true" />Protected
				<span class="switch demo" aria-hidden="true"><span class="knob"></span></span
				>Configurable</span
			>
		{/if}
		{#if view?.isPresident}
			<a class="o-link presidents" href="/app/access/presidents">President Team</a>
		{/if}
	</div>

	<CacheNote savedAt={access.savedAt} online={shell.online} failed={access.error !== null} />

	{#if notice}
		<p class="o-notice" role="status">
			<Check size={16} strokeWidth={2} aria-hidden="true" />{notice}
		</p>
	{/if}

	{#if !view && !loadError}
		<div class="o-skeleton" aria-hidden="true"></div>
		<p class="visually-hidden" role="status">Loading roles and access</p>
	{:else if loadError || !view}
		<div class="o-error" role="alert">
			<p>{loadError ?? 'We couldn’t load this.'}</p>
			<button type="button" class="o-ghost" onclick={load}>Try again</button>
		</div>
	{:else if tab === 'roles' && view.rolePermissions}
		<!-- Desktop matrix (R01) -->
		<section class="o-card matrix o-wide-block" aria-label="Role permissions">
			<div class="o-cols">
				<span class="o-grow">Permission</span>
				<span class="c-scope">Scope</span>
				{#each ROLE_ORDER as role (role)}<span class="c-role">{ROLE_COLUMN[role]}</span>{/each}
			</div>
			{#each catalogue.groups as group (group.title)}
				{@const locked = groupLocked(group.keys)}
				<button
					type="button"
					class="group"
					aria-expanded={isOpen(group.title)}
					onclick={() => groupOpen.set(group.title, !isOpen(group.title))}
				>
					<span class="group-title">{group.title}</span>
					<span class="o-sub">{group.keys.length}{locked ? ` · ${locked} protected` : ''}</span>
					<span class="spacer"></span>
					{#if isOpen(group.title)}<ChevronDown
							size={16}
							strokeWidth={1.5}
							aria-hidden="true"
						/>{:else}<ChevronRight size={16} strokeWidth={1.5} aria-hidden="true" />{/if}
				</button>
				{#if isOpen(group.title)}
					{#each group.keys as key (key)}
						<div
							class="perm-row"
							class:dirty={ROLE_ORDER.some((r) => pending.has(cellKey(r, key)))}
						>
							<span class="o-grow perm-name" class:muted={groupLocked([key]) > 0}
								>{permissionLabel(key)}</span
							>
							<span class="c-scope o-sub">{scopeLabel(key)}</span>
							{#each ROLE_ORDER as role (role)}
								<span class="c-role">{@render toggleCell(role, key)}</span>
							{/each}
						</div>
					{/each}
				{/if}
			{/each}
			<div class="perm-row">
				<span class="o-grow perm-name">{permissionLabel('review_financial_evidence')}</span>
				<span class="c-scope o-sub">Assigned</span>
				<span class="assigned">
					<button type="button" class="named" onclick={() => (tab = 'reviewers')}
						>{reviewerCount} named {reviewerCount === 1 ? 'reviewer' : 'reviewers'}
						<ChevronRight size={14} strokeWidth={1.8} aria-hidden="true" /></button
					>
				</span>
			</div>
		</section>

		<!-- Mobile: one role at a time (R02) -->
		<div class="o-narrow-block mobile-roles">
			<div class="chips" role="group" aria-label="Role">
				{#each ROLE_ORDER as role (role)}
					<button
						type="button"
						class="chip"
						aria-pressed={mobileRole === role}
						onclick={() => (mobileRole = role)}>{ROLE_LABELS[role]}</button
					>
				{/each}
			</div>
			{#each catalogue.groups as group (group.title)}
				{@const locked = groupLocked(group.keys)}
				<section class="o-card">
					<button
						type="button"
						class="m-group"
						aria-expanded={isOpen(group.title) && group.title !== 'Own wallet'}
						onclick={() => groupOpen.set(group.title, !isOpen(group.title))}
					>
						<span class="o-stack o-grow">
							<span class="group-title">{group.title}</span>
							<span class="o-sub"
								>{groupOn(group.keys, mobileRole)} of {group.keys.length} on{locked
									? ` · ${locked} locked`
									: ''}</span
							>
						</span>
						{#if isOpen(group.title)}<ChevronDown
								size={16}
								strokeWidth={1.5}
								aria-hidden="true"
							/>{:else}<ChevronRight size={16} strokeWidth={1.5} aria-hidden="true" />{/if}
					</button>
					{#if isOpen(group.title)}
						{#each group.keys as key (key)}
							<div class="m-row" class:dirty={pending.has(cellKey(mobileRole, key))}>
								<span class="o-grow">{permissionLabel(key)}</span>
								{@render toggleCell(mobileRole, key)}
							</div>
						{/each}
					{/if}
				</section>
			{/each}
		</div>

		{#if pending.size > 0}
			<div class="savebar" role="region" aria-label="Unsaved changes">
				<span class="dot" aria-hidden="true"></span>
				<span class="save-count"
					>{pending.size} {pending.size === 1 ? 'unsaved change' : 'unsaved changes'}</span
				>
				<span class="o-sub o-wide save-what">{pendingSummary}{pending.size > 1 ? ' …' : ''}</span>
				<span class="spacer"></span>
				<button type="button" class="o-ghost o-wide" onclick={() => pending.clear()}>Discard</button
				>
				<button
					type="button"
					class="o-primary"
					disabled={!shell.canAct}
					onclick={() => {
						save.reset('save');
						saveOpen = true;
					}}><span class="o-wide">Save changes</span><span class="o-narrow">Save</span></button
				>
			</div>
		{/if}
	{:else if tab === 'access' && view.assignments}
		{#if view.assignments.items.length === 0}
			<p class="o-card o-empty">No cross-access yet.</p>
		{:else}
			<section class="o-card" aria-label="Cross-access">
				<div class="o-cols" aria-hidden="true">
					<span class="o-grow">Person · rules</span>
					<span class="c-when">Created</span>
					<span class="c-act"></span>
				</div>
				<ul class="o-rows">
					{#each view.assignments.items as assignment (assignment.id)}
						<li class="o-row" class:revoked={!!assignment.revokedAt}>
							<span class="o-avatar" aria-hidden="true">{initials(assignment.subject)}</span>
							<span class="o-stack o-grow">
								<span class="o-title"
									>{personName(assignment.subject)}{assignment.revokedAt ? ' · revoked' : ''}</span
								>
								<span class="o-sub">{ruleLine(assignment)}</span>
								<span class="o-sub"
									>“{assignment.reason}” · by {personName(assignment.createdBy)}</span
								>
							</span>
							<span class="c-when o-wide o-sub">{date(assignment.createdAt)}</span>
							<span class="c-act">
								{#if !assignment.revokedAt}
									<button
										type="button"
										class="o-ghost small"
										disabled={!shell.canAct}
										onclick={() => askRevoke(assignment)}>Revoke</button
									>
								{/if}
							</span>
						</li>
					{/each}
				</ul>
			</section>
		{/if}
	{:else if tab === 'reviewers' && view.reviewers}
		<section class="o-card" aria-label="Evidence reviewers">
			<div class="o-cols" aria-hidden="true">
				<span class="o-grow">Reviewer</span>
				<span class="c-roleoffice">Role · office</span>
				<span class="c-when">Assigned</span>
				<span class="c-act"></span>
			</div>
			<ul class="o-rows">
				{#each view.reviewers as reviewer (reviewer.assignmentId)}
					<li class="o-row">
						<span class="o-avatar coral" aria-hidden="true">{initials(reviewer.person)}</span>
						<span class="o-stack o-grow">
							<span class="o-title">{personName(reviewer.person)}</span>
							<span class="o-sub">{reviewer.person?.uid ?? ''}</span>
						</span>
						<span class="c-roleoffice o-wide o-stack">
							<span class="cell-strong">{ROLE_LABELS[reviewer.role]}</span>
							<span class="o-sub">{reviewer.officeName ?? 'Whole network'}</span>
						</span>
						<span class="c-when o-wide cell-strong">{date(reviewer.assignedAt)}</span>
						<span class="c-act">
							<button
								type="button"
								class="o-ghost small"
								disabled={!shell.canAct}
								onclick={() => askRemove(reviewer)}>Remove</button
							>
						</span>
					</li>
				{:else}
					<li class="o-empty">No reviewers yet. Add the people who check payout evidence.</li>
				{/each}
			</ul>
			<div class="add-reviewer">
				<label class="o-search grow-search">
					<Search size={16} strokeWidth={2} aria-hidden="true" />
					<span class="visually-hidden">Find a member by name or UID</span>
					<input
						type="search"
						placeholder="Find a member by name or UID"
						bind:value={reviewerQuery}
						oninput={searchReviewers}
					/>
				</label>
				<button
					type="button"
					class="o-primary"
					disabled={!reviewerPick || !shell.canAct}
					onclick={openAssign}>Add</button
				>
			</div>
			{#if reviewerResults.length > 0 && !reviewerPick}
				<ul class="results" aria-label="Matching members">
					{#each reviewerResults as result (result.membershipId)}
						<li>
							<button type="button" class="result" onclick={() => (reviewerPick = result)}>
								<span class="o-avatar sm" aria-hidden="true">{initials(result.person)}</span>
								<span class="o-stack">
									<span class="o-title">{personName(result.person)}</span>
									<span class="o-sub"
										>{result.person?.uid ?? ''} · {ROLE_LABELS[result.role]} · {result.officeName ??
											'President Team'}</span
									>
								</span>
							</button>
						</li>
					{/each}
				</ul>
			{:else if reviewerPick}
				<p class="o-sub picked">
					Selected: {personName(reviewerPick.person)} · {ROLE_LABELS[reviewerPick.role]} · {reviewerPick.officeName ??
						'President Team'}
					<button type="button" class="o-link" onclick={() => (reviewerPick = null)}>Change</button>
				</p>
			{/if}
		</section>
	{/if}
</div>

<OrgDialog
	bind:open={saveOpen}
	pose="roles"
	title="Save role permissions?"
	subtitle={`${pending.size} ${pending.size === 1 ? 'change' : 'changes'} · applies right away`}
	confirmLabel="Save changes"
	mobileConfirmLabel="Save"
	busy={save.busy}
	error={save.error}
	pinError={save.pinError}
	onConfirm={submitSave}
/>

<OrgDialog
	bind:open={grantOpen}
	pose="cross-access"
	title="New cross-access rule"
	subtitle="Specific permissions, not a role"
	confirmLabel="Save rule"
	wide
	busy={grant.busy}
	error={grant.error}
	pinError={grant.pinError}
	validate={checkGrant}
	onConfirm={submitGrant}
>
	<div class="o-field">
		<label for="grant-subject">Person (UID)</label>
		<input
			id="grant-subject"
			class="o-input o-mono"
			placeholder="EW-00000"
			autocomplete="off"
			autocapitalize="characters"
			bind:value={subjectUid}
		/>
	</div>
	<div class="o-field">
		<label for="grant-permission">Permissions</label>
		<div class="tokens">
			{#each grantPermissions as permission (permission)}
				<span class="token"
					>{permissionLabel(permission)}<button
						type="button"
						aria-label={`Remove ${permissionLabel(permission)}`}
						onclick={() => (grantPermissions = grantPermissions.filter((p) => p !== permission))}
						><X size={14} strokeWidth={2} /></button
					></span
				>
			{/each}
			<span class="add-token">
				<WheelPicker
					id="grant-permission"
					label="Permission"
					title="Add a permission"
					confirmText="Add"
					triggerText="+ Add"
					action
					searchPlaceholder="Search permissions"
					disabled={addable.length === 0}
					options={addable.map((key) => ({ value: key, label: permissionLabel(key) }))}
					value={null}
					onchange={(key) => {
						if (!grantPermissions.includes(key)) grantPermissions = [...grantPermissions, key];
					}}
				/>
			</span>
		</div>
	</div>
	<div class="pair">
		<fieldset class="o-field bare">
			<legend class="o-field-label">Effect</legend>
			<div class="o-tabs seg">
				<label class="o-tab"
					><input type="radio" name="effect" value="allow" bind:group={ruleEffect} /><span
						>Grant</span
					></label
				>
				<label class="o-tab"
					><input type="radio" name="effect" value="deny" bind:group={ruleEffect} /><span>Deny</span
					></label
				>
			</div>
		</fieldset>
		<fieldset class="o-field bare">
			<legend class="o-field-label">Scope</legend>
			<div class="o-tabs seg">
				<label class="o-tab"
					><input type="radio" name="scope" value="tenant" bind:group={scopeType} /><span
						>Workspace</span
					></label
				>
				<label class="o-tab"
					><input type="radio" name="scope" value="office_subtree" bind:group={scopeType} /><span
						>Office</span
					></label
				>
				<label class="o-tab"
					><input type="radio" name="scope" value="member" bind:group={scopeType} /><span
						>Member</span
					></label
				>
			</div>
		</fieldset>
	</div>
	{#if scopeType === 'office_subtree'}
		<div class="o-field">
			<label for="grant-office">Office and everything under it</label>
			<WheelPicker
				id="grant-office"
				class="o-input"
				label="Office"
				options={(view?.offices ?? []).map((office) => ({ value: office.id, label: office.name }))}
				value={scopeOffice || null}
				onchange={(id) => (scopeOffice = id)}
			/>
		</div>
	{:else if scopeType === 'member'}
		<div class="o-field">
			<label for="grant-member">Member (UID)</label>
			<input
				id="grant-member"
				class="o-input o-mono"
				placeholder="EW-00000"
				bind:value={scopeUid}
			/>
		</div>
	{/if}
	<div class="pair">
		<div class="o-field">
			<label for="grant-starts">Starts</label>
			<input id="grant-starts" class="o-input" type="date" min={today()} bind:value={startsOn} />
		</div>
		{#if ruleEffect === 'allow'}
			<div class="o-field">
				<label for="grant-expires">Expires <span class="o-sub">optional</span></label>
				<input
					id="grant-expires"
					class="o-input"
					type="date"
					min={today()}
					bind:value={expiresOn}
				/>
			</div>
		{/if}
	</div>
</OrgDialog>

<OrgDialog
	bind:open={revokeOpen}
	pose="cross-access"
	title="Revoke cross-access?"
	subtitle={revokeTarget ? `${personName(revokeTarget.subject)} · every rule in it` : undefined}
	confirmLabel="Revoke"
	tone="danger"
	busy={revoke.busy}
	error={revoke.error}
	pinError={revoke.pinError}
	onConfirm={submitRevoke}
/>

<OrgDialog
	bind:open={assignOpen}
	pose="reviewers"
	title="Add reviewer"
	subtitle={reviewerPick
		? `${personName(reviewerPick.person)} · never their own operations`
		: undefined}
	confirmLabel="Add reviewer"
	mobileConfirmLabel="Add"
	busy={assign.busy}
	error={assign.error}
	pinError={assign.pinError}
	onConfirm={submitAssign}
/>

<OrgDialog
	bind:open={removeOpen}
	pose="reviewers"
	title="Remove reviewer?"
	subtitle={removeTarget ? personName(removeTarget.person) : undefined}
	confirmLabel="Remove"
	tone="danger"
	busy={remove.busy}
	error={remove.error}
	pinError={remove.pinError}
	onConfirm={submitRemove}
/>

<style>
	.spacer {
		flex: 1;
	}

	.legend {
		align-items: center;
		gap: 8px;
		color: var(--o-strong);
		font-size: 13px;
	}

	.presidents {
		font-size: 13px;
	}

	.o-wide-block {
		display: none;
	}

	.mobile-roles {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.chips {
		display: flex;
		gap: 8px;
		overflow-x: auto;
		scrollbar-width: none;
	}

	.chip {
		flex-shrink: 0;
		height: 40px;
		padding: 0 18px;
		border: 1px solid var(--o-edge);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--o-strong);
		font: inherit;
		font-size: var(--text-14);
		cursor: pointer;
	}

	.chip[aria-pressed='true'] {
		border-color: transparent;
		background: var(--color-text);
		color: var(--color-canvas);
		font-weight: var(--font-weight-semibold);
	}

	.m-group,
	.group {
		display: flex;
		align-items: center;
		gap: 8px;
		width: 100%;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		text-align: left;
		cursor: pointer;
	}

	.m-group {
		min-height: 56px;
		padding: 12px 16px;
		border-bottom: 1px solid var(--o-row);
	}

	.group-title {
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
	}

	.m-row {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 52px;
		padding: 0 16px;
		border-bottom: 1px solid var(--o-row);
		font-size: var(--text-14);
	}

	.dirty {
		background: color-mix(in oklab, var(--color-text) 3%, transparent);
		box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--color-text) 8%, transparent);
	}

	.switch {
		display: flex;
		align-items: center;
		flex-shrink: 0;
		width: 36px;
		height: 22px;
		padding: 2px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: #2a2f31;
		cursor: pointer;
	}

	.switch .knob {
		width: 16px;
		height: 16px;
		border-radius: var(--radius-pill);
		background: var(--o-faint);
	}

	.switch[aria-checked='true'],
	.switch.demo {
		justify-content: flex-end;
		padding: 3px;
		border-color: transparent;
		background: var(--color-accent);
	}

	.switch[aria-checked='true'] .knob,
	.switch.demo .knob {
		background: #fff4ef;
	}

	.switch:disabled {
		cursor: not-allowed;
		opacity: 0.6;
	}

	.switch:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 2px;
	}

	.locked {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		color: var(--o-faint);
		font-size: var(--text-12);
	}

	.locked.on {
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.savebar {
		position: sticky;
		bottom: calc(104px + env(safe-area-inset-bottom));
		z-index: 2;
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 10px 10px 10px 20px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: var(--o-raised);
		box-shadow: #000000cc 0px 20px 50px -20px;
	}

	.savebar .dot {
		flex-shrink: 0;
		width: 8px;
		height: 8px;
		border-radius: var(--radius-pill);
		background: var(--color-accent);
	}

	.save-count {
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
	}

	.save-what {
		font-size: var(--text-14);
	}

	.revoked {
		opacity: 0.6;
	}

	.c-act {
		display: flex;
		justify-content: flex-end;
		flex-shrink: 0;
	}

	.small {
		min-height: 36px;
		padding: 0 16px;
		font-size: var(--text-14);
	}

	.cell-strong {
		color: var(--o-strong);
		font-size: 13px;
	}

	.add-reviewer {
		display: flex;
		gap: 12px;
		padding: 16px;
	}

	.grow-search {
		flex: 1;
	}

	.results {
		margin: 0 16px 16px;
		padding: 6px;
		list-style: none;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: var(--o-raised);
	}

	.result {
		display: flex;
		align-items: center;
		gap: 12px;
		width: 100%;
		min-height: 52px;
		padding: 6px 10px;
		border: 0;
		border-radius: 10px;
		background: transparent;
		color: inherit;
		font: inherit;
		text-align: left;
		cursor: pointer;
	}

	.result:hover,
	.result:focus-visible {
		background: var(--o-selected);
	}

	.picked {
		display: flex;
		gap: 8px;
		align-items: center;
		padding: 0 16px 16px;
	}

	.pair {
		display: grid;
		grid-template-columns: 1fr;
		gap: 16px;
	}

	.bare {
		margin: 0;
		padding: 0;
		border: 0;
	}

	.seg .o-tab {
		flex: 1;
		height: 40px;
		font-size: var(--text-14);
	}

	.tokens {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 8px;
		min-height: 54px;
		padding: 10px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: var(--o-field);
	}

	.token {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		height: 32px;
		padding: 0 6px 0 12px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: var(--o-raised);
		font-size: 13px;
	}

	.token button {
		display: flex;
		border: 0;
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}

	.add-token :global(.wp-trigger) {
		width: auto;
		height: 32px;
		padding: 0 10px;
		border: 1px dashed var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--o-strong);
		font-size: 13px;
	}

	.add-token :global(.wp-chevron) {
		display: none;
	}

	@media (min-width: 1024px) {
		.o-wide-block {
			display: block;
		}

		.o-narrow-block {
			display: none;
		}

		.legend {
			display: inline-flex;
		}

		.matrix .o-cols {
			height: 48px;
			gap: 8px;
		}

		.group {
			height: 40px;
			padding: 0 20px;
			border-bottom: 1px solid var(--o-row);
		}

		.perm-row {
			display: flex;
			align-items: center;
			gap: 8px;
			height: 52px;
			padding: 0 20px;
			border-bottom: 1px solid var(--o-row);
		}

		.perm-row:last-child {
			border-bottom: 0;
		}

		.perm-name {
			font-size: var(--text-14);
			line-height: 18px;
		}

		.perm-name.muted {
			color: var(--o-strong);
		}

		.c-scope {
			flex-shrink: 0;
			width: 80px;
			color: var(--o-faint);
		}

		.c-role {
			display: flex;
			justify-content: center;
			flex-shrink: 0;
			width: 96px;
		}

		.assigned {
			display: flex;
			justify-content: flex-end;
			width: calc(5 * 96px + 4 * 8px);
		}

		.named {
			display: inline-flex;
			align-items: center;
			gap: 6px;
			height: 28px;
			padding: 0 12px;
			border: 1px solid var(--color-accent-ring);
			border-radius: var(--radius-pill);
			background: var(--color-accent-subtle);
			color: var(--o-coral-ink);
			font: inherit;
			font-size: 12px;
			cursor: pointer;
		}

		.savebar {
			bottom: 24px;
			padding: 12px 12px 12px 24px;
		}

		.c-when {
			flex-shrink: 0;
			width: 160px;
		}

		.c-roleoffice {
			flex-shrink: 0;
			width: 216px;
		}

		.c-act {
			width: 110px;
		}

		.add-reviewer {
			padding: 16px 20px;
		}

		.results {
			width: 560px;
			margin: 0 20px 20px;
		}

		.pair {
			grid-template-columns: 1fr 1fr;
		}
	}
</style>
