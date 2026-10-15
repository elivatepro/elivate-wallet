<!--
	"Invite a member" (Paper I01 hero action): email, office, role. Member
	invitations go straight out; a leader role also asks for a reason and the
	PIN (step-up, A-05). Same modal recipe as ConfirmDialog (bottom sheet on
	mobile, centred card on desktop). The backend decides authority; the role
	choice here is only what it can accept. Blueprint 38 (Paper TL01/TL01d):
	a By email / Team link switch; the team link tab is TeamLinkPanel.
-->
<script lang="ts">
	import { enterMovesOn } from '#lib/ui/enter-moves-on.js';
	import { Dialog } from 'bits-ui';
	import type { InviteOffice } from '#lib/contract/app.js';
	import type { Role } from '#lib/contract/common.js';
	import { INVITE_EMAIL_PATTERN } from '#lib/contract/invitations.js';
	import { inviteRoles } from '#lib/invitations.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';
	import TeamLinkPanel from './TeamLinkPanel.svelte';

	let {
		open = $bindable(false),
		offices,
		workspace,
		busy = false,
		error = null,
		pinError = null,
		askPin = false,
		membershipId = null,
		canAct = true,
		tab = $bindable('email'),
		linkOfficeId = $bindable(''),
		onSubmit
	}: {
		open?: boolean;
		offices: ReadonlyArray<InviteOffice>;
		workspace: { role: Role; officeId: string | null };
		busy?: boolean;
		error?: string | null;
		pinError?: string | null;
		/** Set after step_up_required so a member invitation can be confirmed too. */
		askPin?: boolean;
		/** The selected workspace; with it the dialog offers team links (Blueprint 38). */
		membershipId?: string | null;
		canAct?: boolean;
		/** Which tab shows; the Invitations page's team link card opens "Team link" (Slice 39). */
		tab?: 'email' | 'link';
		/** The office the Team link tab shows. */
		linkOfficeId?: string;
		onSubmit: (input: {
			email: string;
			officeId: string;
			role: Role;
			reason: string | undefined;
			pin: string | undefined;
		}) => void;
	} = $props();

	let email = $state('');
	let officeId = $state('');
	let role = $state<Role>('member');
	let reason = $state('');
	let fieldError = $state<{ field: 'email' | 'reason'; text: string } | null>(null);

	const office = $derived(offices.find((o) => o.officeId === officeId) ?? offices[0]);
	const roles = $derived(office ? inviteRoles(workspace, office) : (['member'] as Role[]));
	const leader = $derived(role !== 'member');
	/** "as a Member", "on the World Team" (Paper C13 subtitle). */
	const joinsAs = $derived(
		ROLE_LABELS[role].endsWith('Team') ? `on the ${ROLE_LABELS[role]}` : `as a ${ROLE_LABELS[role]}`
	);

	$effect(() => {
		if (open) fieldError = null;
	});
	$effect(() => {
		if (!offices.some((o) => o.officeId === linkOfficeId))
			linkOfficeId = offices[0]?.officeId ?? '';
	});
	const linkOffice = $derived(offices.find((o) => o.officeId === linkOfficeId) ?? offices[0]);
	$effect(() => {
		if (!offices.some((o) => o.officeId === officeId)) officeId = offices[0]?.officeId ?? '';
	});
	$effect(() => {
		if (!roles.includes(role)) role = 'member';
	});

	function submit(event: SubmitEvent) {
		event.preventDefault();
		if (!office) return;
		const data = new FormData(event.currentTarget as HTMLFormElement);
		const pin = String(data.get('pin') ?? '') || undefined;
		const cleanEmail = email.trim();
		if (cleanEmail.length > 254 || !INVITE_EMAIL_PATTERN.test(cleanEmail)) {
			fieldError = { field: 'email', text: 'Enter a valid email address.' };
			return;
		}
		const cleanReason = reason.trim();
		if (leader && (cleanReason.length < 3 || cleanReason.length > 500)) {
			fieldError = { field: 'reason', text: 'Give a reason (3–500 characters).' };
			return;
		}
		fieldError = null;
		onSubmit({
			email: cleanEmail,
			officeId: office.officeId,
			role,
			reason: leader ? cleanReason : undefined,
			pin
		});
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="confirm-overlay" />
		<Dialog.Content class="confirm-dialog">
			<!-- Paper C13/C14: the grainy band with Root holding the invitation;
			     TL01: Root holding the door for a team link. -->
			<header class="stage">
				<span class="shade" aria-hidden="true"></span>
				{#if tab === 'link'}
					<RootImage pose="team-link" class="stage-root" sizes="124px" eager />
				{:else}
					<RootImage pose="invite-member" class="stage-root" sizes="118px" eager />
				{/if}
				<Dialog.Title class="stage-title">Invite a member</Dialog.Title>
				{#if tab === 'link' && linkOffice}
					<p class="stage-sub">Joins {linkOffice.name} as a Member</p>
				{:else if office}
					<p class="stage-sub">Joins {office.name} {joinsAs}</p>
				{/if}
			</header>
			{#if membershipId}
				<div class="tabs" role="tablist" aria-label="How to invite">
					<button
						type="button"
						role="tab"
						aria-selected={tab === 'email'}
						onclick={() => (tab = 'email')}>By email</button
					>
					<button
						type="button"
						role="tab"
						aria-selected={tab === 'link'}
						onclick={() => (tab = 'link')}>Team link</button
					>
				</div>
			{/if}
			{#if tab === 'link' && membershipId}
				<TeamLinkPanel {offices} bind:officeId={linkOfficeId} {membershipId} {canAct} />
			{:else}
				<form onsubmit={submit} novalidate {@attach enterMovesOn}>
					<div class="body" class:tabbed={!!membershipId}>
						{#if error}<p class="error" role="alert">{error}</p>{/if}

						<label class="label" for="invite-email">Email address</label>
						<input
							id="invite-email"
							class="input"
							type="email"
							inputmode="email"
							autocomplete="off"
							autocapitalize="off"
							spellcheck="false"
							maxlength="254"
							bind:value={email}
							aria-invalid={fieldError?.field === 'email' ? 'true' : undefined}
							aria-describedby={fieldError?.field === 'email' ? 'invite-email-error' : undefined}
						/>
						{#if fieldError?.field === 'email'}
							<p class="field-error" id="invite-email-error">{fieldError.text}</p>
						{/if}

						{#if offices.length > 1}
							<label class="label" for="invite-office">Office</label>
							<div class="pick">
								<WheelPicker
									id="invite-office"
									label="Office"
									options={offices.map((o) => ({ value: o.officeId, label: o.name }))}
									value={officeId}
									onchange={(id) => (officeId = id)}
								/>
							</div>
						{:else if office}
							<p class="label">Office</p>
							<p class="fixed">{office.name}</p>
						{/if}

						{#if roles.length > 1}
							<fieldset class="roles">
								<legend class="label">Role</legend>
								<div class="segmented">
									{#each roles as r (r)}
										<label class="segment">
											<input type="radio" name="role" value={r} bind:group={role} />
											<span>{ROLE_LABELS[r]}</span>
										</label>
									{/each}
								</div>
							</fieldset>
						{/if}

						{#if leader}
							<label class="label" for="invite-reason">Reason</label>
							<textarea
								id="invite-reason"
								class="input"
								rows="2"
								maxlength="500"
								bind:value={reason}
								aria-invalid={fieldError?.field === 'reason' ? 'true' : undefined}
								aria-describedby={fieldError?.field === 'reason'
									? 'invite-reason-error'
									: undefined}></textarea>
							{#if fieldError?.field === 'reason'}
								<p class="field-error" id="invite-reason-error">{fieldError.text}</p>
							{/if}
						{/if}
						{#if (leader || askPin) && open}
							<PinField id="invite-pin" name="pin" label="Your PIN" error={pinError} />
						{/if}
					</div>
					<div class="actions">
						<Dialog.Close class="confirm-cancel" type="button">Cancel</Dialog.Close>
						<button class="go" type="submit" disabled={busy || !office} aria-busy={busy}>
							Send invitation
						</button>
					</div>
				</form>
			{/if}
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	.stage {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		height: 150px;
		padding: 24px 28px;
		overflow: clip;
		/* The sheet's 24 px corners, inside its 1 px border. */
		border-radius: 23px 23px 0 0;
		background: var(--color-surface) url('/auth-bg/desktop-dark.jpg') 60% 30% / cover;
	}

	.shade {
		position: absolute;
		inset: 0;
		background: linear-gradient(
			90deg,
			color-mix(in oklab, var(--color-surface) 94%, transparent) 0%,
			color-mix(in oklab, var(--color-surface) 55%, transparent) 55%,
			transparent 100%
		);
	}

	.stage :global(.stage-root) {
		position: absolute;
		right: 40px;
		bottom: -12px;
		width: 118px;
		height: 158px;
	}

	.stage :global(.stage-title) {
		position: relative;
		color: var(--color-text);
		font-size: 24px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.01em;
		line-height: 30px;
	}

	.stage-sub {
		position: relative;
		max-width: calc(100% - 150px);
		padding-top: 4px;
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: 20px;
	}

	.body {
		display: flex;
		flex-direction: column;
		gap: 10px;
		max-height: min(70dvh, 640px);
		overflow-y: auto;
		padding: 28px;
	}

	.body.tabbed {
		padding-top: 8px;
		/* Blueprint 38: the tabs add a row; header, tabs and actions stay on screen. */
		max-height: max(160px, calc(100dvh - 330px - env(safe-area-inset-bottom)));
	}

	@media (min-width: 1024px) {
		.body.tabbed {
			max-height: max(160px, min(640px, calc(100dvh - 500px)));
		}
	}

	.tabs {
		display: flex;
		gap: 4px;
		margin: 24px 28px 8px;
		padding: 4px;
		border-radius: var(--radius-pill);
		border: 1px solid color-mix(in oklab, var(--color-text) 10%, transparent);
		background: color-mix(in oklab, var(--color-canvas) 60%, transparent);
	}

	.tabs button {
		flex: 1;
		height: 36px;
		border: 0;
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-muted);
		font: inherit;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		cursor: pointer;
	}

	.tabs button[aria-selected='true'] {
		background: var(--color-raised);
		color: var(--color-text);
	}

	.tabs button:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 1px;
	}

	.error {
		padding: 10px 14px;
		border-radius: var(--radius-12);
		background: color-mix(in oklab, var(--color-danger) 12%, transparent);
		color: var(--color-text);
		font-size: var(--text-14);
	}

	.label {
		margin-top: 8px;
		padding: 0;
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
	}

	.input,
	.pick :global(.wp-trigger) {
		min-height: 48px;
		padding: 0 16px;
		border-radius: var(--radius-12);
		border: 1px solid color-mix(in oklab, var(--color-text) 16%, transparent);
		background: color-mix(in oklab, var(--color-canvas) 60%, transparent);
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
	}

	textarea.input {
		min-height: 72px;
		padding: 12px 16px;
		line-height: var(--leading-24);
		resize: vertical;
	}

	.input:focus,
	.pick :global(.wp-trigger:focus) {
		outline: none;
		border-color: var(--color-accent);
	}

	.fixed {
		color: var(--color-muted);
		font-size: 15px;
	}

	.field-error {
		color: var(--color-danger);
		font-size: var(--text-14);
	}

	.roles {
		display: flex;
		flex-direction: column;
		gap: 10px;
		margin: 0;
		padding: 0;
		border: 0;
	}

	.segmented {
		display: flex;
		gap: 2px;
		padding: 4px;
		border-radius: var(--radius-12);
		border: 1px solid color-mix(in oklab, var(--color-text) 10%, transparent);
		background: color-mix(in oklab, var(--color-canvas) 60%, transparent);
	}

	.segment {
		position: relative;
		display: flex;
		flex: 1;
		align-items: center;
		justify-content: center;
		height: 36px;
		border-radius: var(--radius-8);
		color: var(--color-muted);
		font-size: var(--text-14);
		cursor: pointer;
	}

	.segment input {
		position: absolute;
		opacity: 0;
		pointer-events: none;
	}

	.segment:has(input:checked) {
		background: var(--color-raised);
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.segment:has(input:focus-visible) {
		outline: 2px solid var(--focus-ring);
		outline-offset: 1px;
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 12px;
		padding: 20px 28px;
		border-top: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
	}

	.go {
		min-height: 48px;
		padding: 0 22px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--button-primary-bg);
		box-shadow: var(--auth-button-shadow);
		color: var(--button-primary-ink);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.go:disabled {
		opacity: var(--opacity-disabled);
	}
</style>
