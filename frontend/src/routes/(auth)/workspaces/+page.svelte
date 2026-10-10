<!--
	Workspace picker, Paper "App — Screens v3": G10 (choose), G11 (no workspace
	yet), G12 (invitations for you). One form per row (POST) so it works before
	JavaScript. Membership and invitation ids travel in the form body, never in
	the URL.
-->
<script lang="ts">
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import { ROLE_LABELS, TENANT_STATUS_LABELS } from '#lib/labels.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();

	const hasInvitations = $derived(data.invitations.length > 0);
	const isEmpty = $derived(data.workspaces.length === 0 && !hasInvitations);
	useRoot(
		() => (hasInvitations ? 'invitations' : isEmpty ? 'no-workspace' : 'workspaces'),
		() => (isEmpty ? 'lg' : 'sm')
	);

	let accepting: string | null = $state(null);

	/** A retry after an unknown outcome reuses the key it was first sent with. */
	const keyFor = (invitationId: string, fresh: string) => {
		const retry = (form as { retry?: { invitationId: string; idempotencyKey: string } } | null)
			?.retry;
		return retry?.invitationId === invitationId ? retry.idempotencyKey : fresh;
	};
</script>

<svelte:head><title>Choose a workspace · Elivate Wallet</title></svelte:head>

{#if isEmpty}
	<AuthHeading
		eyebrow="Workspaces"
		title="No workspace yet"
		lead="When you start or join a network, it appears here."
	/>
	<p class="id-row">
		<span class="id-label">Your Elivate ID</span>
		<span class="id-value">{data.uid}</span>
	</p>
	<!-- Blueprint 16: founders start a network here (PL01). -->
	<PrimaryButton label="Start a network" href="/setup" />
	<SignOutLink label="Sign out" />
{:else}
	<AuthHeading eyebrow="Workspaces" title="Choose a workspace" />
	{#if form?.message}<FormAlert message={form.message} />{/if}

	{#snippet workspaceRows()}
		<ul class="list">
			{#each data.workspaces as workspace (workspace.membershipId)}
				{@const status = TENANT_STATUS_LABELS[workspace.tenantStatus]}
				<li>
					<form method="POST" action="?/select">
						<input type="hidden" name="membershipId" value={workspace.membershipId} />
						{#if data.next}<input type="hidden" name="next" value={data.next} />{/if}
						<button type="submit" class="row" disabled={!workspace.selectable}>
							<span class="text">
								<span class="name">{workspace.tenantName}</span>
								<span class="meta">
									{ROLE_LABELS[workspace.role]}{workspace.officeName
										? ` · ${workspace.officeName}`
										: ''}
								</span>
								{#if !workspace.selectable}
									<span class="status">Membership suspended</span>
								{:else if status}
									<span class="status">{status}</span>
								{/if}
							</span>
							<span class="chev" aria-hidden="true"
								><ChevronRight size={20} strokeWidth={1.6} /></span
							>
						</button>
					</form>
				</li>
			{/each}
		</ul>
	{/snippet}

	{#if hasInvitations}
		<section class="section" aria-labelledby="invitations-label">
			<h2 class="section-label" id="invitations-label">Invitations for you</h2>
			<ul class="list">
				{#each data.invitations as invitation (invitation.invitationId)}
					<li class="row invite">
						<span class="text">
							<span class="name">{invitation.tenantName}</span>
							<span class="meta">{ROLE_LABELS[invitation.role]} · {invitation.officeName}</span>
						</span>
						<form
							method="POST"
							action="?/accept"
							onsubmit={() => (accepting = invitation.invitationId)}
						>
							<input type="hidden" name="invitationId" value={invitation.invitationId} />
							<input
								type="hidden"
								name="idempotencyKey"
								value={keyFor(invitation.invitationId, invitation.idempotencyKey)}
							/>
							<button
								type="submit"
								class="accept"
								disabled={accepting !== null}
								aria-busy={accepting === invitation.invitationId ? 'true' : undefined}
								aria-label={`Accept invitation to ${invitation.tenantName}`}>Accept</button
							>
						</form>
					</li>
				{/each}
			</ul>
		</section>
		{#if data.workspaces.length > 0}
			<section class="section" aria-labelledby="workspaces-label">
				<h2 class="section-label" id="workspaces-label">Your workspaces</h2>
				{@render workspaceRows()}
			</section>
		{/if}
	{:else}
		{@render workspaceRows()}
	{/if}
	<AltLink label="Start a network" href="/setup" />
	<SignOutLink label="Sign out" />
{/if}

<style>
	.id-row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		height: 52px;
		flex-shrink: 0;
		padding: 0 16px;
		border: 1px solid var(--auth-field-border);
		border-radius: var(--radius-12);
		background: var(--auth-field-bg);
	}

	.id-label {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.id-value {
		color: var(--color-text);
		font-family: var(--font-mono);
		font-size: 15px;
		letter-spacing: var(--tracking-label);
		line-height: var(--leading-20);
	}

	.section {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.section-label {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.14em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.list {
		display: flex;
		flex-direction: column;
		gap: 8px;
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.row {
		display: flex;
		align-items: center;
		gap: 12px;
		width: 100%;
		min-height: 64px;
		padding: 12px 8px 12px 16px;
		border-radius: var(--radius-12);
		border: 1px solid var(--auth-field-border);
		background: var(--auth-field-bg);
		color: var(--color-text);
		text-align: left;
		cursor: pointer;
	}

	.row:hover:not(:disabled, .invite) {
		border-color: color-mix(in oklab, var(--color-accent) 60%, transparent);
	}

	.row:disabled {
		cursor: not-allowed;
		opacity: var(--opacity-disabled);
	}

	.row.invite {
		padding-right: 10px;
		border-color: #ff7f4f59;
		background: #3a251f80;
		cursor: default;
	}

	.text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.name {
		font-size: var(--text-16);
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-24);
	}

	.meta {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.status {
		color: var(--color-warning);
		font-size: 13px;
		line-height: 18px;
	}

	.chev {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: var(--hit-min);
		height: var(--hit-min);
		color: var(--color-muted);
	}

	.accept {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		height: var(--hit-min);
		padding: 0 18px;
		border: 0;
		border-radius: var(--radius-pill);
		background-image: var(--button-primary-bg);
		color: var(--button-primary-ink);
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-20);
		cursor: pointer;
	}

	.accept:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	:global([data-theme='light']) .row.invite {
		border-color: color-mix(in oklab, var(--color-accent) 35%, transparent);
		background: var(--color-accent-subtle);
	}

	@media (prefers-color-scheme: light) {
		:global([data-theme='system']) .row.invite {
			border-color: color-mix(in oklab, var(--color-accent) 35%, transparent);
			background: var(--color-accent-subtle);
		}
	}
</style>
