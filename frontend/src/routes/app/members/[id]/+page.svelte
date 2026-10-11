<!--
	Member detail, Paper "App — Screens v2" R07 (desktop) / R08 (mobile), with
	Suspend R09/R10, Move R11/R12 and End R13/R14 (reason + PIN, W-05). The
	wallet card shows this network's money per currency, only when the leader
	may see it (never mixed). Reactivate reuses the suspend dialog; "Change
	role" opens a stub page (no Paper composition yet). Blueprint 22: a
	director's "Funds" row (President Team) switches "funds not managed" with a
	reason and the PIN; it says why when the wallet still holds money.
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { DropdownMenu } from 'bits-ui';
	import ArrowRight from '@lucide/svelte/icons/arrow-right';
	import Building from '@lucide/svelte/icons/building-2';
	import Check from '@lucide/svelte/icons/check';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import CircleMinus from '@lucide/svelte/icons/circle-minus';
	import Pause from '@lucide/svelte/icons/pause';
	import Play from '@lucide/svelte/icons/play';
	import UserCog from '@lucide/svelte/icons/user-cog';
	import type { Role } from '#lib/contract/common.js';
	import { AppOrgRoutes, MemberView, type MembershipAction } from '#lib/contract/org-admin.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import { cachedPage } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { formatMoney, hiddenMoney } from '#lib/money.js';
	import {
		fundsRow,
		LEADER_ROLE,
		OFFICE_TYPE_LABELS,
		personName,
		STATUS_LABELS
	} from '#lib/org.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import OrgDialog from '#lib/ui/org/OrgDialog.svelte';
	import OrgHero from '#lib/ui/org/OrgHero.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';

	const shell = getContext<Shell>('shell');
	const workspace = $derived(shell.state.kind === 'ready' ? shell.state.view.workspace : null);
	const id = $derived(page.params.id ?? '');

	let notice = $state<string | null>(null);

	// Blueprint 23: a member opens from cache (kind 'members', part = the
	// membership id), then refreshes; another [id] reads its own copy.
	const read = cachedPage(shell, {
		kind: 'members',
		part: () => id.toLowerCase(),
		load: () => loadView(AppOrgRoutes.member(id), MemberView)
	});
	const view = $derived(read.data);
	const loadError = $derived(view ? null : read.error);
	const load = () => read.reload();
	// Gone, or no longer visible to this person: drop the cached copy.
	$effect(() => {
		if (read.errorStatus === 403 || read.errorStatus === 404) read.clear();
	});

	const member = $derived(view?.member ?? null);
	const place = $derived(member?.office?.name ?? 'President Team');
	const leader = $derived(
		member?.officeLeaders.find((l) => l.person?.uid !== member?.person?.uid) ?? null
	);
	const anyAction = $derived(
		!!member &&
			(member.actions.suspend ||
				member.actions.move ||
				member.actions.end ||
				member.actions.changeRole)
	);
	const date = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }).format(
			new Date(iso)
		);

	// ── Lifecycle dialogs ──
	const command = new OrgCommand();
	let dialog = $state<MembershipAction | null>(null);
	let open = $state(false);
	let toOffice = $state('');
	let newRole = $state<string>('');
	/** N03: role only, never the office (owner decision 2026-10-08). */
	const roleChoices = $derived.by(() => {
		if (!member?.office) return [] as Role[];
		return (['member', LEADER_ROLE[member.office.type]] as Role[]).filter((r) => r !== member.role);
	});

	function ask(action: MembershipAction) {
		command.reset(`${id}:${action}`);
		notice = null;
		toOffice = '';
		newRole = roleChoices[0] ?? '';
		dialog = action;
		open = true;
	}

	const DONE: Partial<Record<MembershipAction, string>> = {
		suspend: 'Membership suspended.',
		reactivate: 'Membership reactivated.',
		end: 'Membership ended.',
		move: 'Moved to the new office.',
		role: 'Role changed.'
	};

	/** Blueprint 22: the Funds row (President Team, or anyone once switched). */
	const funds = $derived(member ? fundsRow(member) : null);

	async function confirm({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!workspace || !dialog) return;
		const action = dialog;
		const result = await command.send(
			AppOrgRoutes.memberAction(id, action),
			'POST',
			{
				reason,
				...(action === 'move' ? { toOfficeId: toOffice } : {}),
				...(action === 'role' ? { role: newRole } : {}),
				...(action === 'funds' ? { notManaged: !member?.fundsNotManaged } : {}),
				...(pin ? { pin } : {})
			},
			workspace.membershipId
		);
		if (!result) return;
		open = false;
		notice =
			action === 'funds'
				? result.fundsNotManaged === true
					? 'Funds marked as not managed.'
					: 'Funds are managed again.'
				: (DONE[action] ?? null);
		// A move or role change ends this membership: show the one that replaced it.
		const moved = typeof result.membershipId === 'string' ? result.membershipId : null;
		if ((action === 'move' || action === 'role') && moved && moved !== id) {
			await goto(`/app/members/${moved}`);
			return;
		}
		await load();
	}

	const moveTargets = $derived((view?.offices ?? []).filter((o) => o.id !== member?.office?.id));
</script>

<svelte:head
	><title>{member ? personName(member.person) : 'Member'} · Elivate Wallet</title></svelte:head
>

<div class="o-page">
	<a class="back o-sub" href="/app/members">‹ Members</a>
	<CacheNote savedAt={read.savedAt} online={shell.online} failed={read.error !== null} />

	{#if !view && !loadError}
		<div class="o-skeleton" aria-hidden="true"></div>
		<p class="visually-hidden" role="status">Loading the member</p>
	{:else if loadError || !member || !view}
		<div class="o-error" role="alert">
			<p>{loadError ?? 'We couldn’t load this member.'}</p>
			<button type="button" class="o-ghost" onclick={load}>Try again</button>
		</div>
	{:else}
		<OrgHero
			id="member-heading"
			pose="member"
			title={personName(member.person)}
			line={`${member.person?.uid ?? ''} · ${ROLE_LABELS[member.role]} · ${place}`}
		>
			{#snippet actions()}
				{#if anyAction}
					<DropdownMenu.Root>
						<DropdownMenu.Trigger class="hero-chip" disabled={!shell.canAct}>
							Actions <ChevronDown size={16} strokeWidth={1.8} aria-hidden="true" />
						</DropdownMenu.Trigger>
						<DropdownMenu.Portal>
							<DropdownMenu.Content class="popover member-menu" sideOffset={8} align="start">
								<div class="menu-group">
									{#if member.actions.suspend}
										{#if member.status === 'suspended'}
											<DropdownMenu.Item class="menu-row" onSelect={() => ask('reactivate')}>
												<Play size={16} strokeWidth={1.8} aria-hidden="true" /><span
													class="menu-label">Reactivate membership</span
												>
											</DropdownMenu.Item>
										{:else}
											<DropdownMenu.Item class="menu-row" onSelect={() => ask('suspend')}>
												<Pause size={16} strokeWidth={1.8} aria-hidden="true" /><span
													class="menu-label">Suspend membership</span
												>
											</DropdownMenu.Item>
										{/if}
									{/if}
									{#if member.actions.move}
										<DropdownMenu.Item class="menu-row" onSelect={() => ask('move')}>
											<ArrowRight size={16} strokeWidth={1.8} aria-hidden="true" /><span
												class="menu-label">Move to another office</span
											>
										</DropdownMenu.Item>
									{/if}
									{#if member.actions.changeRole}
										<DropdownMenu.Item class="menu-row" onSelect={() => ask('role')}>
											<UserCog size={16} strokeWidth={1.8} aria-hidden="true" /><span
												class="menu-label">Change role</span
											>
										</DropdownMenu.Item>
									{/if}
								</div>
								{#if member.actions.end}
									<div class="pop-divider"></div>
									<div class="menu-group">
										<DropdownMenu.Item class="menu-row danger" onSelect={() => ask('end')}>
											<CircleMinus size={16} strokeWidth={1.8} aria-hidden="true" /><span
												class="menu-label">End membership</span
											>
										</DropdownMenu.Item>
									</div>
								{/if}
							</DropdownMenu.Content>
						</DropdownMenu.Portal>
					</DropdownMenu.Root>
				{/if}
				<span class="o-pill status-chip" data-status={member.status}
					>● {STATUS_LABELS[member.status]}</span
				>
			{/snippet}
		</OrgHero>

		{#if notice}
			<p class="o-notice" role="status">
				<Check size={16} strokeWidth={2} aria-hidden="true" />{notice}
			</p>
		{/if}

		<div class="grid">
			<div class="main-col">
				<section class="o-card facts" aria-label="Details">
					<dl>
						<div>
							<dt>UID</dt>
							<dd class="o-mono">{member.person?.uid ?? '—'}</dd>
						</div>
						<div>
							<dt>Email</dt>
							<dd>{member.emailMasked ?? '—'}</dd>
						</div>
						<div>
							<dt>Office</dt>
							<dd class="office-cell">
								<span>{place}</span>
								{#if leader}<span class="o-sub o-wide">Leader {personName(leader.person)}</span
									>{/if}
							</dd>
						</div>
						<div>
							<dt>Role</dt>
							<dd>{ROLE_LABELS[member.role]}{member.isPrimary ? ' · primary' : ''}</dd>
						</div>
						{#if funds}
							<div>
								<dt>Funds</dt>
								<dd class="funds-cell">
									<span class="o-stack">
										<span>{funds.notManaged ? 'Not managed' : 'Managed'}</span>
										{#if funds.notManaged}
											<span class="o-sub"
												>Holds no money. Still records income and runs the team.</span
											>
										{:else if funds.blocked}
											<span class="o-sub"
												>Can’t switch while their wallet holds money or has something in progress.</span
											>
										{/if}
									</span>
									{#if funds.action}
										<button
											type="button"
											class="o-ghost funds-action"
											disabled={!shell.canAct || read.savedAt !== null}
											onclick={() => ask('funds')}
											>{funds.action === 'clear'
												? 'Manage funds again'
												: 'Funds not managed'}</button
										>
									{/if}
								</dd>
							</div>
						{/if}
						<div>
							<dt>{member.status === 'ended' ? 'Ended' : 'Joined'}</dt>
							<dd>{date(member.endedAt ?? member.startedAt)}</dd>
						</div>
					</dl>
				</section>

				<section class="o-card" aria-labelledby="history-heading">
					<header class="o-card-head"><h2 id="history-heading">Recent activity</h2></header>
					{#if member.history.length === 0}
						<p class="o-empty">Nothing yet.</p>
					{:else}
						<ul class="o-rows">
							{#each member.history as event, i (i)}
								<li class="o-row">
									<span class="o-icon-tile" aria-hidden="true"
										><Building size={16} strokeWidth={1.5} /></span
									>
									<span class="o-stack o-grow">
										<span class="o-title"
											>{event.action === 'created'
												? `Joined ${place}`
												: `Membership ${event.action}`}</span
										>
										<span class="o-sub">{date(event.at)} · by {personName(event.actor)}</span>
									</span>
								</li>
							{/each}
						</ul>
					{/if}
				</section>
			</div>

			<div class="side-col">
				{#if view.balances}
					<section class="o-card o-card-pad wallet" aria-labelledby="wallet-heading">
						<div class="wallet-head">
							<h2 id="wallet-heading" class="card-title">Wallet</h2>
							{#if view.walletId}<a
									class="wallet-open"
									href={`/app/wallets?wallet=${view.walletId}`}>Open</a
								>{/if}
						</div>
						{#each view.balances as balance (balance.currency)}
							<div class="balance">
								<span class="o-label o-mono">{balance.currency} balance</span>
								<span class="big"
									>{shell.hideAmounts
										? hiddenMoney(balance.currency)
										: formatMoney(balance.posted, balance.currency)}</span
								>
							</div>
						{:else}
							<p class="o-sub">No money in this network yet.</p>
						{/each}
					</section>
				{/if}
				<section class="o-card o-card-pad" aria-labelledby="ms-heading">
					<h2 id="ms-heading" class="card-title">Memberships</h2>
					{#each member.memberships as ms (ms.membershipId)}
						<a class="ms" href={`/app/members/${ms.membershipId}`}>
							<span class="o-icon-tile" aria-hidden="true"
								><Building size={16} strokeWidth={1.5} /></span
							>
							<span class="o-stack o-grow">
								<span class="o-title">{ms.officeName ?? 'President Team'}</span>
								<span class="o-sub">{ROLE_LABELS[ms.role]}{ms.isPrimary ? ' · primary' : ''}</span>
							</span>
							<span class="ms-status" data-status={ms.status}>{STATUS_LABELS[ms.status]}</span>
						</a>
					{:else}
						<p class="o-sub">No open memberships.</p>
					{/each}
				</section>
			</div>
		</div>
	{/if}
</div>

{#if member}
	{#if dialog === 'suspend' || dialog === 'reactivate'}
		<OrgDialog
			bind:open
			pose="member-suspend"
			title={dialog === 'suspend' ? 'Suspend membership' : 'Reactivate membership'}
			subtitle={`${place} membership only`}
			confirmLabel={dialog === 'suspend' ? 'Suspend membership' : 'Reactivate membership'}
			mobileConfirmLabel={dialog === 'suspend' ? 'Suspend' : 'Reactivate'}
			tone={dialog === 'suspend' ? 'danger' : 'accent'}
			busy={command.busy}
			error={command.error}
			pinError={command.pinError}
			onConfirm={confirm}
		/>
	{:else if dialog === 'move'}
		<OrgDialog
			bind:open
			pose="member-move"
			title="Move to another office"
			subtitle={`From ${place}; history stays where it is`}
			confirmLabel="Move membership"
			mobileConfirmLabel="Move"
			busy={command.busy}
			error={command.error}
			pinError={command.pinError}
			validate={() => (toOffice ? null : 'Choose the new office.')}
			onConfirm={confirm}
		>
			<div class="o-field">
				<label for="move-office">New office</label>
				<WheelPicker
					id="move-office"
					class="o-input"
					label="New office"
					placeholder="Choose an office"
					searchPlaceholder="Search offices"
					options={moveTargets.map((office) => ({
						value: office.id,
						label: office.name,
						hint: OFFICE_TYPE_LABELS[office.type]
					}))}
					value={toOffice || null}
					onchange={(id) => (toOffice = id)}
				/>
			</div>
		</OrgDialog>
	{:else if dialog === 'role'}
		<OrgDialog
			bind:open
			pose="member-role"
			title="Change role"
			subtitle="Same office. Wallet and history stay intact"
			confirmLabel="Change role"
			busy={command.busy}
			error={command.error}
			pinError={command.pinError}
			validate={() => (newRole ? null : 'Choose the new role.')}
			onConfirm={confirm}
		>
			<div class="o-field">
				<label for="role-new">New role</label>
				<WheelPicker
					id="role-new"
					class="o-input"
					label="New role"
					options={roleChoices.map((role) => ({ value: role, label: ROLE_LABELS[role] }))}
					value={newRole || null}
					onchange={(role) => (newRole = role)}
				/>
				<p class="o-sub currently">
					Currently <span class="cur">{ROLE_LABELS[member.role]} · {place}</span>
				</p>
			</div>
		</OrgDialog>
	{:else if dialog === 'funds'}
		<OrgDialog
			bind:open
			pose="member-role"
			title={member.fundsNotManaged ? 'Manage funds again' : 'Funds not managed'}
			subtitle={member.fundsNotManaged
				? 'Their wallet works again; setup asks for their NIN, phone and bank'
				: 'They stay a director but hold no money'}
			confirmLabel={member.fundsNotManaged ? 'Manage funds again' : 'Mark funds not managed'}
			mobileConfirmLabel="Confirm"
			busy={command.busy}
			error={command.error}
			pinError={command.pinError}
			onConfirm={confirm}
		/>
	{:else if dialog === 'end'}
		<OrgDialog
			bind:open
			pose="member-end"
			title="End membership"
			subtitle={`${place}; wallet and history stay`}
			confirmLabel="End membership"
			mobileConfirmLabel="End"
			tone="danger"
			busy={command.busy}
			error={command.error}
			pinError={command.pinError}
			onConfirm={confirm}
		/>
	{/if}
{/if}

<style>
	.wallet-head {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
	}

	.wallet-open {
		color: var(--color-accent);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		text-decoration: none;
	}

	.currently {
		font-size: 13px;
	}

	.cur {
		color: var(--color-text);
		margin-left: 4px;
	}

	.back {
		align-self: flex-start;
		font-size: var(--text-14);
		text-decoration: none;
	}

	.status-chip {
		height: 28px;
	}

	:global(.popover.member-menu) {
		width: 280px;
	}

	:global(.menu-row.danger) {
		color: var(--color-danger);
	}

	.grid {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.main-col,
	.side-col {
		display: flex;
		flex-direction: column;
		gap: 16px;
		min-width: 0;
	}

	.side-col {
		order: -1;
	}

	h2 {
		font: inherit;
	}

	.card-title {
		font-size: 17px;
		font-weight: var(--font-weight-semibold);
		line-height: 22px;
	}

	.facts dl {
		margin: 0;
		padding: 4px 16px;
	}

	.facts dl > div {
		display: flex;
		align-items: center;
		gap: 16px;
		min-height: 52px;
		border-bottom: 1px solid var(--o-row);
	}

	.facts dl > div:last-child {
		border-bottom: 0;
	}

	dt {
		flex-shrink: 0;
		width: 96px;
		color: var(--o-strong);
		font-size: var(--text-14);
	}

	dd {
		flex: 1;
		min-width: 0;
		margin: 0;
		font-size: var(--text-14);
		overflow-wrap: anywhere;
	}

	.funds-cell {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 8px 0;
	}

	.funds-action {
		flex-shrink: 0;
	}

	.office-cell {
		display: flex;
		justify-content: space-between;
		gap: 12px;
	}

	.balance {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding-bottom: 12px;
		border-bottom: 1px solid var(--o-row);
	}

	.balance:last-child {
		padding-bottom: 0;
		border-bottom: 0;
	}

	.balance .o-label {
		font-size: 11px;
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	.big {
		font-size: 24px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.01em;
		line-height: 30px;
		font-variant-numeric: tabular-nums;
		overflow-wrap: anywhere;
	}

	.ms {
		display: flex;
		align-items: center;
		gap: 12px;
		color: inherit;
		text-decoration: none;
	}

	.ms-status {
		font-size: 13px;
	}

	.ms-status[data-status='active'] {
		color: var(--color-success);
	}

	.ms-status[data-status='suspended'] {
		color: var(--color-danger);
	}

	@media (min-width: 1024px) {
		.grid {
			flex-direction: row;
			align-items: flex-start;
			gap: 24px;
		}

		.main-col {
			flex: 1;
			gap: 24px;
		}

		.side-col {
			order: 0;
			flex-shrink: 0;
			width: 360px;
			gap: 24px;
		}

		.facts dl {
			padding: 8px 24px;
		}

		dt {
			width: 180px;
		}

		.big {
			font-size: 30px;
			line-height: 36px;
		}
	}
</style>
