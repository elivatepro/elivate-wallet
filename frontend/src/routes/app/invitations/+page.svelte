<!--
	Invitations, Paper "App — Screens v3" I01 (list, resend/revoke menu; mobile
	bottom sheet) and I02 (revoke with a reason). For leaders holding
	invite_members: the invitations of their workspace's subtree, a status
	filter, "Invite a member", Resend link (fresh link, old one dies, 7 days
	restart) and Revoke. Emails are the leader's own entries and are shown as
	given; they never go into a URL, and the link token never reaches this page.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option, type Schema } from 'effect';
	import { Dialog, DropdownMenu } from 'bits-ui';
	import Ban from '@lucide/svelte/icons/ban';
	import Check from '@lucide/svelte/icons/check';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import Clock from '@lucide/svelte/icons/clock';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import Mail from '@lucide/svelte/icons/mail';
	import Plus from '@lucide/svelte/icons/plus';
	import RotateCw from '@lucide/svelte/icons/rotate-cw';
	import TimerOff from '@lucide/svelte/icons/timer-off';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import { AppRoutes, InvitationsView, type InviteOffice } from '#lib/contract/app.js';
	import type { Role } from '#lib/contract/common.js';
	import type { ApiFailure } from '#lib/contract/errors.js';
	import {
		CreatedInvitation,
		ReissuedInvitation,
		RevokedInvitation,
		type Invitation,
		type InvitationStatus
	} from '#lib/contract/invitations.js';
	import { followGate } from '#lib/client/account.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import { cachedPage, MorePages, type PageLoaded } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import {
		activityLabel,
		describeFailure,
		keepsKey,
		rowActions,
		sentLabel,
		STATUS_FILTERS,
		STATUS_LABELS,
		type CommandAction,
		type Outcome,
		type StatusFilter
	} from '#lib/invitations.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import ConfirmDialog from '#lib/ui/app/ConfirmDialog.svelte';
	import InviteDialog from '#lib/ui/app/InviteDialog.svelte';
	import SeatLimitDialog from '#lib/ui/app/SeatLimitDialog.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';

	const shell = getContext<Shell>('shell');
	const STATUS_ICONS = { pending: Clock, accepted: CircleCheck, expired: TimerOff, revoked: Ban };

	let filter = $state<StatusFilter>('all');
	let offices = $state<ReadonlyArray<InviteOffice> | null>(null);
	let notice = $state<{ ok: boolean; text: string } | null>(null);
	let now = $state(Date.now());

	const workspace = $derived(shell.state.kind === 'ready' ? shell.state.view.workspace : null);
	const canInvite = $derived(!!offices && offices.length > 0);

	/** One page of invitations (the first, or the one after `cursor`). */
	async function read(cursor?: string): Promise<PageLoaded<InvitationsView>> {
		// Local, built and read once: not state, so no reactive wrapper needed.
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const params = new URLSearchParams();
		if (filter !== 'all') params.set('status', filter);
		if (cursor) params.set('cursor', cursor);
		const query = params.size ? `?${params}` : '';
		const exit = await Effect.runPromiseExit(
			getJson(`${AppRoutes.invitations.path}${query}`, InvitationsView)
		);
		if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
		const failure = failureOf(exit);
		const status = failure?._tag === 'BackendError' ? failure.status : null;
		// Slice 21: a lapsed PIN or session goes to its gate and comes back here.
		if (followGate(failure, '/app/invitations')) return { ok: false, text: '', status };
		const text =
			failure?._tag === 'BackendError' ? failure.message : 'We couldn’t load the invitations.';
		return { ok: false, text, status };
	}

	// Blueprint 23: the unfiltered first page opens from cache (kind
	// 'invitations'; rows carry no link or token), then refreshes. A status
	// filter is its own read, shown but never kept.
	const view = cachedPage(shell, {
		kind: 'invitations',
		part: () => `status-${filter}`,
		cacheable: () => filter === 'all',
		load: () => read()
	});
	const pages = new MorePages<Invitation>(() => view.data?.page ?? null);
	const items = $derived(pages.items);
	const nextCursor = $derived(pages.nextCursor);
	const loaded = $derived(view.data !== null);
	const loadError = $derived(view.data ? null : view.error || null);
	const load = () => view.reload();
	/** Why there is no "Invite a member": an invitation always goes into an office. */
	const noOffices = $derived(loaded && !canInvite ? (offices ? 'none' : 'unavailable') : null);
	const president = $derived(workspace?.role === 'president_team_member');

	// Offices come with every first page; kept while another filter loads.
	$effect(() => {
		const shown = view.data;
		if (!shown) return;
		offices = shown.offices;
		now = Date.now();
	});

	async function loadMore() {
		await pages.more(async (cursor) => {
			const result = await read(cursor);
			return result.ok ? { ok: true, value: result.value.page } : result;
		});
		if (pages.error) notice = { ok: false, text: pages.error };
	}

	/** The filter is part of the read: changing it reads again. */
	function setFilter(value: StatusFilter) {
		filter = value;
	}

	const failureOf = <A,>(exit: Exit.Exit<A, ApiFailure>) =>
		Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) : undefined;

	/** Sends one command; the caller owns the key and what to show. */
	async function command<S extends Schema.ConstraintDecoder<unknown>>(
		path: string,
		body: Record<string, unknown>,
		schema: S
	): Promise<{ ok: true } | { ok: false; failure: ApiFailure | undefined }> {
		if (!workspace || !shell.canAct) return { ok: false, failure: undefined };
		const exit = await Effect.runPromiseExit(
			sendCommand(path, 'POST', body, workspace.membershipId, schema)
		);
		return Exit.isSuccess(exit) ? { ok: true } : { ok: false, failure: failureOf(exit) };
	}

	const outcome = (action: CommandAction, failure: ApiFailure | undefined): Outcome => {
		const result = describeFailure(action, failure);
		if (result.kind === 'locked') window.location.assign('/pin/locked');
		return result;
	};

	// ── Resend (I01 menu): immediate; a leader-role invitation asks for the PIN.
	let resendKey = newKey();
	let resendFor: string | null = null;
	let resendBusy = $state<string | null>(null);
	let resendTarget = $state<Invitation | null>(null);
	let resendPinOpen = $state(false);
	let resendError = $state<string | null>(null);
	let resendPinError = $state<string | null>(null);

	async function resend(invitation: Invitation, pin?: string) {
		if (resendFor !== invitation.invitationId) {
			resendFor = invitation.invitationId;
			resendKey = newKey();
		}
		resendBusy = invitation.invitationId;
		notice = null;
		resendError = null;
		resendPinError = null;
		const result = await command(
			AppRoutes.reissueInvitation(invitation.invitationId).path,
			{ idempotencyKey: resendKey, ...(pin ? { pin } : {}) },
			ReissuedInvitation
		);
		resendBusy = null;
		if (result.ok) {
			resendKey = newKey();
			resendPinOpen = false;
			notice = { ok: true, text: `New link sent to ${invitation.email}.` };
			await load();
			return;
		}
		if (!keepsKey(result.failure)) resendKey = newKey();
		const said = outcome('resend', result.failure);
		if (said.kind === 'pin') {
			resendTarget = invitation;
			resendPinError = said.text;
			resendPinOpen = true;
		} else if (said.kind === 'message') {
			if (resendPinOpen) resendError = said.text;
			else notice = { ok: false, text: said.text };
		}
	}

	// ── Revoke (I02): reason + PIN.
	let revokeKey = newKey();
	let revokeTarget = $state<Invitation | null>(null);
	let revokeOpen = $state(false);
	let revokeBusy = $state(false);
	let revokeError = $state<string | null>(null);
	let revokePinError = $state<string | null>(null);

	function askRevoke(invitation: Invitation) {
		if (revokeTarget?.invitationId !== invitation.invitationId) revokeKey = newKey();
		revokeTarget = invitation;
		revokeError = null;
		revokePinError = null;
		notice = null;
		revokeOpen = true;
	}

	async function revoke({ reason, pin }: { reason: string; pin: string | undefined }) {
		const target = revokeTarget;
		if (!target) return;
		revokeBusy = true;
		revokeError = null;
		revokePinError = null;
		const result = await command(
			AppRoutes.revokeInvitation(target.invitationId).path,
			{ reason, idempotencyKey: revokeKey, ...(pin ? { pin } : {}) },
			RevokedInvitation
		);
		revokeBusy = false;
		if (result.ok) {
			revokeKey = newKey();
			revokeOpen = false;
			notice = { ok: true, text: `Invitation for ${target.email} revoked.` };
			await load();
			return;
		}
		if (!keepsKey(result.failure)) revokeKey = newKey();
		const said = outcome('revoke', result.failure);
		if (said.kind === 'pin') revokePinError = said.text;
		else if (said.kind === 'message') revokeError = said.text;
	}

	// ── Invite a member (I01 hero action).
	let inviteKey = newKey();
	let inviteOpen = $state(false);
	let inviteVersion = $state(0);
	let inviteBusy = $state(false);
	let inviteAskPin = $state(false);
	let inviteError = $state<string | null>(null);
	let invitePinError = $state<string | null>(null);
	/** Blueprint 16: the network is full (E03; PL05 for those who can pay). */
	let seatLimitOpen = $state(false);
	const canUpgrade = $derived(
		shell.state.kind === 'ready' &&
			((shell.state.view.capabilities?.permissions ?? []).includes('manage_subscription') ||
				shell.state.view.capabilities?.billingOwner === true)
	);

	function openInvite() {
		inviteError = null;
		invitePinError = null;
		notice = null;
		inviteOpen = true;
	}

	async function invite(input: {
		email: string;
		officeId: string;
		role: Role;
		reason: string | undefined;
		pin: string | undefined;
	}) {
		inviteBusy = true;
		inviteError = null;
		invitePinError = null;
		const { pin, reason, ...rest } = input;
		const result = await command(
			AppRoutes.createInvitation.path,
			{
				...rest,
				...(reason ? { reason } : {}),
				...(pin ? { pin } : {}),
				idempotencyKey: inviteKey
			},
			CreatedInvitation
		);
		inviteBusy = false;
		if (result.ok) {
			inviteKey = newKey();
			inviteOpen = false;
			inviteAskPin = false;
			inviteVersion += 1;
			notice = { ok: true, text: `Invitation sent to ${input.email}.` };
			await load();
			return;
		}
		if (!keepsKey(result.failure)) inviteKey = newKey();
		if (
			result.failure?._tag === 'BackendError' &&
			result.failure.code === 'conflict' &&
			result.failure.details.reason === 'seat_limit_reached'
		) {
			inviteOpen = false;
			seatLimitOpen = true;
			return;
		}
		const said = outcome('create', result.failure);
		if (said.kind === 'pin') {
			inviteAskPin = true;
			invitePinError = said.text;
		} else if (said.kind === 'message') inviteError = said.text;
	}

	// ── Mobile bottom sheet (I01 mobile).
	let sheetTarget = $state<Invitation | null>(null);
	let sheetOpen = $state(false);

	function openSheet(invitation: Invitation) {
		sheetTarget = invitation;
		sheetOpen = true;
	}

	function fromSheet(action: (invitation: Invitation) => void) {
		const target = sheetTarget;
		sheetOpen = false;
		if (target) action(target);
	}

	const describe = (invitation: Invitation) =>
		`${ROLE_LABELS[invitation.role]} · ${invitation.officeName}`;

	const emptyText = (value: StatusFilter) =>
		value === 'all'
			? 'No invitations yet.'
			: `No ${STATUS_LABELS[value as InvitationStatus].toLowerCase()} invitations.`;
</script>

<svelte:head><title>Invitations · Elivate Wallet</title></svelte:head>

{#snippet statusIcon(status: InvitationStatus)}
	{@const Icon = STATUS_ICONS[status]}
	<Icon size={14} strokeWidth={2} aria-hidden="true" />
{/snippet}

<div class="page">
	<section class="hero" aria-labelledby="invitations-heading">
		<div class="shade" aria-hidden="true"></div>
		<div class="grain" aria-hidden="true"></div>
		<RootImage
			pose="invitations-manage"
			class="hero-root"
			sizes="(min-width: 1024px) 180px, 116px"
			eager
		/>
		<div class="hero-text">
			<h1 id="invitations-heading">Invitations</h1>
			<p class="hero-line">Each link lasts 7 days.</p>
		</div>
		{#if canInvite}
			<button type="button" class="invite" disabled={!shell.canAct} onclick={openInvite}>
				<Plus size={18} strokeWidth={2.2} aria-hidden="true" />Invite a member
			</button>
		{:else if noOffices === 'none' && president}
			<a class="invite" href="/app/offices">
				<Plus size={18} strokeWidth={2.2} aria-hidden="true" />Add an office
			</a>
		{/if}
	</section>

	{#if noOffices}
		<p class="hint" role="status">
			{#if noOffices === 'unavailable'}
				We couldn’t load the offices you can invite into.
				<button type="button" class="link" onclick={() => load()}>Try again</button>
			{:else if president}
				Everyone joins into an office. Add your first office, then invite people into it.
			{:else}
				There’s no active office you can invite into.
			{/if}
		</p>
	{/if}

	<CacheNote savedAt={view.savedAt} online={shell.online} failed={!!view.error} />

	<fieldset class="filter">
		<legend class="visually-hidden">Show invitations</legend>
		{#each STATUS_FILTERS as option (option.value)}
			<label class="segment">
				<input
					type="radio"
					name="invitation-status"
					value={option.value}
					checked={filter === option.value}
					onchange={() => setFilter(option.value)}
				/>
				<span>{option.label}</span>
			</label>
		{/each}
	</fieldset>

	{#if notice}
		<p class="notice" class:bad={!notice.ok} role={notice.ok ? 'status' : 'alert'}>
			{#if notice.ok}<Check size={16} strokeWidth={2} aria-hidden="true" />{:else}<TriangleAlert
					size={16}
					strokeWidth={2}
					aria-hidden="true"
				/>{/if}
			{notice.text}
		</p>
	{/if}

	{#if !loaded && !loadError}
		<div class="skeleton" aria-hidden="true"></div>
		<p class="visually-hidden" role="status">Loading invitations</p>
	{:else if loadError}
		<div class="load-error" role="alert">
			<p>{loadError}</p>
			<button type="button" class="ghost" onclick={() => load()}>Try again</button>
		</div>
	{:else if items.length === 0}
		<p class="empty">{emptyText(filter)}</p>
	{:else}
		<section class="table" aria-label="Invitations">
			<div class="cols" aria-hidden="true">
				<span class="grow">Invitation</span>
				<span class="c-status">Status</span>
				<span class="c-sent">Sent</span>
				<span class="c-activity">Last activity</span>
				<span class="c-actions"></span>
			</div>
			<ul class="rows">
				{#each items as invitation (invitation.invitationId)}
					{@const activity = activityLabel(invitation, now)}
					{@const actions = rowActions(invitation)}
					<li class="row" class:busy={resendBusy === invitation.invitationId}>
						<span class="avatar" aria-hidden="true"><Mail size={16} strokeWidth={1.8} /></span>
						<span class="who grow">
							<span class="email">{invitation.email}</span>
							<span class="meta wide">{describe(invitation)}</span>
							<span class="meta narrow" data-status={invitation.status}>
								{@render statusIcon(invitation.status)}
								<span>{STATUS_LABELS[invitation.status]}</span>
								<span class="tone" data-tone={activity.tone}>· {activity.text}</span>
							</span>
						</span>
						<span class="c-status wide">
							<span class="pill" data-status={invitation.status}>
								{@render statusIcon(invitation.status)}{STATUS_LABELS[invitation.status]}
							</span>
						</span>
						<span class="c-sent wide">{sentLabel(invitation)}</span>
						<span class="c-activity wide" data-tone={activity.tone}>
							{#if invitation.status === 'pending' && invitation.delivery === 'failed'}
								<TriangleAlert size={14} strokeWidth={2} aria-hidden="true" />
							{/if}
							{activity.text}
						</span>
						<span class="c-actions">
							{#if actions.resend || actions.revoke}
								<span class="wide">
									<DropdownMenu.Root>
										<DropdownMenu.Trigger
											class="more"
											aria-label={`Actions for ${invitation.email}`}
											disabled={!shell.canAct || resendBusy !== null}
										>
											<Ellipsis size={18} strokeWidth={1.8} />
										</DropdownMenu.Trigger>
										<DropdownMenu.Portal>
											<DropdownMenu.Content class="popover row-menu" sideOffset={6} align="end">
												<div class="menu-group">
													{#if actions.resend}
														<DropdownMenu.Item class="menu-row" onSelect={() => resend(invitation)}>
															<RotateCw size={16} strokeWidth={1.8} aria-hidden="true" />
															<span class="menu-label">Resend link</span>
														</DropdownMenu.Item>
													{/if}
													<DropdownMenu.Item
														class="menu-row danger"
														onSelect={() => askRevoke(invitation)}
													>
														<Ban size={16} strokeWidth={1.8} aria-hidden="true" />
														<span class="menu-label">Revoke invitation</span>
													</DropdownMenu.Item>
												</div>
											</DropdownMenu.Content>
										</DropdownMenu.Portal>
									</DropdownMenu.Root>
								</span>
								<button
									type="button"
									class="more narrow"
									aria-label={`Actions for ${invitation.email}`}
									disabled={!shell.canAct || resendBusy !== null}
									onclick={() => openSheet(invitation)}
								>
									<Ellipsis size={18} strokeWidth={1.8} />
								</button>
							{/if}
						</span>
					</li>
				{/each}
			</ul>
		</section>
		{#if nextCursor}
			<button
				type="button"
				class="ghost more-rows"
				disabled={pages.loading}
				aria-busy={pages.loading}
				onclick={loadMore}>Show more</button
			>
		{/if}
	{/if}
</div>

<Dialog.Root bind:open={sheetOpen}>
	<Dialog.Portal>
		<Dialog.Overlay class="confirm-overlay" />
		<Dialog.Content class="confirm-dialog invite-sheet">
			<span class="handle" aria-hidden="true"></span>
			{#if sheetTarget}
				<Dialog.Title class="sheet-title">{sheetTarget.email}</Dialog.Title>
				<Dialog.Description class="sheet-meta">{describe(sheetTarget)}</Dialog.Description>
				<div class="sheet-actions">
					{#if rowActions(sheetTarget).resend}
						<button type="button" class="sheet-row" onclick={() => fromSheet(resend)}>
							<RotateCw size={18} strokeWidth={1.8} aria-hidden="true" />Resend link
						</button>
					{/if}
					<button type="button" class="sheet-row danger" onclick={() => fromSheet(askRevoke)}>
						<Ban size={18} strokeWidth={1.8} aria-hidden="true" />Revoke invitation
					</button>
				</div>
			{/if}
			<Dialog.Close class="confirm-cancel sheet-cancel" type="button">Cancel</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

{#key revokeTarget?.invitationId}
	<ConfirmDialog
		bind:open={revokeOpen}
		title="Revoke invitation?"
		summary={revokeTarget ? `${revokeTarget.email} · ${describe(revokeTarget)}` : undefined}
		confirmLabel="Revoke"
		cancelLabel="Keep invitation"
		tone="danger"
		busy={revokeBusy}
		error={revokeError}
		pinError={revokePinError}
		onConfirm={revoke}
	/>
{/key}

<ConfirmDialog
	bind:open={resendPinOpen}
	title="Resend the link?"
	summary={resendTarget ? `${resendTarget.email} · ${describe(resendTarget)}` : undefined}
	confirmLabel="Resend link"
	needsReason={false}
	busy={resendBusy !== null}
	error={resendError}
	pinError={resendPinError}
	onConfirm={({ pin }) => resendTarget && resend(resendTarget, pin)}
/>

{#if offices && workspace}
	{#key inviteVersion}
		<InviteDialog
			bind:open={inviteOpen}
			{offices}
			workspace={{ role: workspace.role, officeId: workspace.officeId }}
			busy={inviteBusy}
			error={inviteError}
			pinError={invitePinError}
			askPin={inviteAskPin}
			onSubmit={invite}
		/>
	{/key}
{/if}

<SeatLimitDialog bind:open={seatLimitOpen} {canUpgrade} />

<style>
	.page {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	/* Hero: BalanceCard recipe (dark in both themes), Paper I01 header card. */
	.hero {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: space-between;
		gap: 20px;
		min-height: 156px;
		padding: 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 22px;
		background-color: #1a1d1e;
		background-image: url('/auth-bg/mobile-dark.jpg');
		background-size: cover;
		background-position: 50% 30%;
		background-origin: border-box;
		isolation: isolate;
		color: #f2f4f4;
	}

	.shade,
	.grain {
		position: absolute;
		inset: 0;
		pointer-events: none;
	}

	.shade {
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(18.5% -0.002 -0.003 / 92%) 0%,
			oklab(18.5% -0.002 -0.003 / 55%) 55%,
			oklab(18.5% -0.002 -0.003 / 0%) 100%
		);
	}

	.grain {
		background-image: url('/auth-bg/grain-128.webp');
		background-size: 128px 128px;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}

	.hero :global(.hero-root) {
		position: absolute;
		right: 4px;
		bottom: -12px;
		width: 116px;
		height: 156px;
	}

	.hero-text,
	.invite {
		position: relative;
	}

	.hero-text {
		display: flex;
		flex-direction: column;
		gap: 4px;
		max-width: calc(100% - 110px);
	}

	h1 {
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 32px;
	}

	.hero-line {
		color: #a9b0b3;
		font-size: 13px;
		line-height: 18px;
	}

	.invite {
		display: inline-flex;
		align-items: center;
		align-self: flex-start;
		gap: 8px;
		height: 40px;
		padding: 0 16px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--button-primary-bg);
		box-shadow:
			#ffffff59 0px 1px 0px inset,
			var(--button-primary-glow) 0px 10px 28px -10px;
		color: var(--button-primary-ink);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	a.invite {
		text-decoration: none;
	}

	.invite:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	/* Status filter: full-width segmented control on mobile (owner rule). */
	.filter {
		display: flex;
		gap: 2px;
		margin: 0;
		padding: 4px;
		min-width: 0;
		overflow-x: auto;
		border-radius: var(--radius-12);
		border: 1px solid color-mix(in oklab, var(--color-text) 10%, transparent);
		background: color-mix(in oklab, var(--color-surface) 70%, var(--color-canvas));
		scrollbar-width: none;
	}

	.segment {
		position: relative;
		display: flex;
		flex: 1 0 auto;
		align-items: center;
		justify-content: center;
		height: 36px;
		padding: 0 10px;
		border-radius: var(--radius-8);
		color: var(--color-muted);
		font-size: 13px;
		white-space: nowrap;
		cursor: pointer;
	}

	.segment input {
		position: absolute;
		opacity: 0;
		pointer-events: none;
	}

	.segment:has(input:checked) {
		background: var(--color-raised);
		box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--color-text) 8%, transparent);
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.segment:has(input:focus-visible) {
		outline: 2px solid var(--focus-ring);
		outline-offset: -2px;
	}

	.hint {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: 20px;
	}

	.link {
		padding: 0;
		border: 0;
		background: none;
		color: var(--color-text);
		font: inherit;
		font-weight: var(--font-weight-medium);
		text-decoration: underline;
		cursor: pointer;
	}

	.notice {
		display: flex;
		align-items: center;
		gap: 8px;
		color: var(--color-success);
		font-size: var(--text-14);
		overflow-wrap: anywhere;
	}

	.notice.bad {
		color: var(--color-warning);
	}

	.notice :global(svg) {
		flex-shrink: 0;
	}

	.skeleton {
		height: 260px;
		border-radius: 18px;
		background: var(--color-surface);
	}

	.load-error {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 12px;
		color: var(--color-danger);
	}

	.empty {
		padding: 32px 20px;
		border-radius: 18px;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		background: var(--color-surface);
		color: var(--color-muted);
		font-size: var(--text-14);
		text-align: center;
	}

	.table {
		overflow: clip;
		border-radius: 18px;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		background: var(--color-surface);
	}

	.cols {
		display: none;
	}

	.rows {
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.row {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 64px;
		padding: 10px 8px 10px 16px;
		border-bottom: 1px solid color-mix(in oklab, var(--color-text) 4%, transparent);
	}

	.row:last-child {
		border-bottom: 0;
	}

	/* Selection: slightly lighter fill, quiet outline (never an accent bar). */
	.row:has(:global([data-state='open'])) {
		background: color-mix(in oklab, var(--color-text) 3%, transparent);
		box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.row.busy {
		opacity: 0.7;
	}

	.grow {
		flex: 1;
		min-width: 0;
	}

	.avatar {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--color-muted);
	}

	.who {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.email {
		overflow: hidden;
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.meta {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.meta.narrow {
		display: flex;
		align-items: center;
		gap: 4px;
		flex-wrap: wrap;
	}

	.wide {
		display: none;
	}

	[data-status='pending'] {
		color: var(--color-info);
	}

	[data-status='accepted'] {
		color: var(--color-success);
	}

	[data-status='expired'] {
		color: var(--color-muted);
	}

	[data-status='revoked'] {
		color: var(--color-danger);
	}

	.meta.narrow .tone {
		color: var(--color-muted);
	}

	[data-tone='warning'],
	.meta.narrow .tone[data-tone='warning'] {
		color: var(--color-warning);
	}

	.c-actions {
		display: flex;
		justify-content: center;
		flex-shrink: 0;
		width: 44px;
	}

	:global(.more) {
		display: flex;
		align-items: center;
		justify-content: center;
		width: var(--hit-min);
		height: var(--hit-min);
		border: 0;
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}

	:global(.more:disabled) {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	:global(.more[data-state='open']),
	:global(.more:hover:not(:disabled)) {
		background: var(--color-raised);
		color: var(--color-text);
	}

	:global(.popover.row-menu) {
		width: 220px;
	}

	:global(.menu-row.danger) {
		color: var(--color-danger);
	}

	.ghost {
		min-height: 44px;
		padding: 0 20px;
		border-radius: var(--radius-pill);
		border: 1px solid color-mix(in oklab, var(--color-text) 20%, transparent);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		cursor: pointer;
	}

	.more-rows {
		align-self: center;
	}

	/* Mobile action sheet (I01 mobile). */
	:global(.invite-sheet) {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 12px 20px calc(20px + env(safe-area-inset-bottom));
	}

	:global(.invite-sheet .handle) {
		align-self: center;
		width: 36px;
		height: 4px;
		margin-bottom: 18px;
		border-radius: var(--radius-pill);
		background: var(--color-border);
	}

	:global(.sheet-title) {
		overflow-wrap: anywhere;
		font-size: 17px;
		font-weight: var(--font-weight-semibold);
		line-height: 22px;
	}

	:global(.sheet-meta) {
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	:global(.sheet-actions) {
		display: flex;
		flex-direction: column;
		margin: 16px 0;
		overflow: clip;
		border-radius: 14px;
		background: var(--color-raised);
	}

	:global(.sheet-row) {
		display: flex;
		align-items: center;
		gap: 14px;
		min-height: 56px;
		padding: 0 16px;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		text-align: left;
		cursor: pointer;
	}

	:global(.sheet-row + .sheet-row) {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	:global(.sheet-row.danger) {
		color: var(--color-danger);
	}

	:global(.sheet-cancel) {
		width: 100%;
	}

	@media (min-width: 1024px) {
		.page {
			gap: 24px;
		}

		.hero {
			min-height: 220px;
			padding: 32px;
			border-radius: var(--radius-24);
		}

		.hero :global(.hero-root) {
			right: 64px;
			bottom: -14px;
			width: 180px;
			height: 242px;
		}

		h1 {
			font-size: 40px;
			line-height: 44px;
		}

		.hero-line {
			font-size: 15px;
			line-height: 20px;
		}

		.invite {
			height: 46px;
			padding: 0 20px;
		}

		.filter {
			align-self: flex-start;
		}

		.segment {
			flex: 0 0 auto;
			height: 32px;
			padding: 0 12px;
		}

		.cols {
			display: flex;
			align-items: center;
			gap: 16px;
			height: 42px;
			padding: 0 20px;
			border-bottom: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
			color: var(--color-muted);
			font-family: var(--font-mono);
			font-size: 11px;
			letter-spacing: 0.08em;
			line-height: 14px;
			text-transform: uppercase;
		}

		.row {
			gap: 16px;
			padding: 0 20px;
		}

		.wide {
			display: flex;
		}

		.narrow,
		.meta.narrow {
			display: none;
		}

		.cols .grow {
			padding-left: 0;
		}

		.c-status,
		.c-sent {
			flex-shrink: 0;
			width: 140px;
		}

		.c-activity {
			display: flex;
			align-items: center;
			gap: 6px;
			flex-shrink: 0;
			width: 180px;
		}

		.rows .c-sent,
		.rows .c-activity {
			color: var(--color-text);
			font-size: 13px;
			line-height: 16px;
		}

		.c-activity[data-tone='muted'] {
			color: var(--color-muted);
		}

		.c-activity[data-tone='warning'] {
			color: var(--color-warning);
		}

		.c-actions {
			width: 44px;
		}

		.pill {
			display: inline-flex;
			align-items: center;
			gap: 6px;
			padding: 3px 10px;
			border-radius: var(--radius-pill);
			background: color-mix(in oklab, currentColor 14%, transparent);
			font-size: var(--text-12);
			line-height: var(--leading-16);
		}
	}
</style>
