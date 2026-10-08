<!--
	"Invite a member" (Paper I01 hero action): email, office, role. Member
	invitations go straight out; a leader role also asks for a reason and the
	PIN (step-up, A-05). Same modal recipe as ConfirmDialog (bottom sheet on
	mobile, centred card on desktop). The backend decides authority; the role
	choice here is only what it can accept.
-->
<script lang="ts">
	import { Dialog } from 'bits-ui';
	import type { InviteOffice } from '#lib/contract/app.js';
	import type { Role } from '#lib/contract/common.js';
	import { INVITE_EMAIL_PATTERN } from '#lib/contract/invitations.js';
	import { inviteRoles } from '#lib/invitations.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import PinField from '#lib/ui/auth/PinField.svelte';

	let {
		open = $bindable(false),
		offices,
		workspace,
		busy = false,
		error = null,
		pinError = null,
		askPin = false,
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

	$effect(() => {
		if (open) fieldError = null;
	});
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
			<form onsubmit={submit} novalidate>
				<div class="body">
					<Dialog.Title class="confirm-title">Invite a member</Dialog.Title>
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
						<select id="invite-office" class="input" bind:value={officeId}>
							{#each offices as o (o.officeId)}<option value={o.officeId}>{o.name}</option>{/each}
						</select>
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
							aria-describedby={fieldError?.field === 'reason' ? 'invite-reason-error' : undefined}
						></textarea>
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
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	.body {
		display: flex;
		flex-direction: column;
		gap: 10px;
		max-height: min(70dvh, 640px);
		overflow-y: auto;
		padding: 28px;
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

	.input {
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

	.input:focus {
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
