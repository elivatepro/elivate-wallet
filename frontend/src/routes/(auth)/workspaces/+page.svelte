<!--
	Workspace picker. Not drawn in Paper "Authentication v2"; built from its
	tokens and panel. One form per workspace (POST ?/select) so it works before
	JavaScript. Membership ids travel in the form body, never in the URL.
-->
<script lang="ts">
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Building from '@lucide/svelte/icons/building-2';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import SignOutLink from '#lib/ui/auth/SignOutLink.svelte';
	import { ROLE_LABELS, TENANT_STATUS_LABELS } from '#lib/labels.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
</script>

<svelte:head><title>Choose a workspace · Elivate Wallet</title></svelte:head>

{#if data.workspaces.length === 0}
	<AuthHeading
		icon={Building}
		eyebrow="Workspaces"
		title="No workspace yet"
		lead="When you start or join a network, it appears here."
	/>
	<p class="uid">Your Elivate ID <strong>{data.uid}</strong></p>
	<SignOutLink label="Sign out" />
{:else}
	<AuthHeading eyebrow="Workspaces" title="Choose a workspace" />
	{#if form?.message}<FormAlert message={form.message} />{/if}
	<ul class="list">
		{#each data.workspaces as workspace (workspace.membershipId)}
			{@const status = TENANT_STATUS_LABELS[workspace.tenantStatus]}
			<li>
				<form method="POST" action="?/select">
					<input type="hidden" name="membershipId" value={workspace.membershipId} />
					<button type="submit" class="row" disabled={!workspace.selectable}>
						<span class="text">
							<span class="name">{workspace.tenantName}</span>
							<span class="meta">
								{ROLE_LABELS[workspace.role]}{workspace.officeName
									? ` · ${workspace.officeName}`
									: ''}
							</span>
							{#if status}<span class="status">{status}</span>{/if}
							{#if !workspace.selectable}<span class="status">Membership suspended</span>{/if}
						</span>
						<span class="chev" aria-hidden="true"><ChevronRight size={20} strokeWidth={1.6} /></span
						>
					</button>
				</form>
			</li>
		{/each}
	</ul>
	<SignOutLink label="Sign out" />
{/if}

<style>
	.uid {
		color: var(--auth-body);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.uid strong {
		color: var(--color-text);
		font-family: var(--font-mono);
		font-weight: var(--font-weight-regular);
		letter-spacing: var(--tracking-label);
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

	.row:hover:not(:disabled) {
		border-color: color-mix(in oklab, var(--color-accent) 60%, transparent);
	}

	.row:disabled {
		cursor: not-allowed;
		opacity: var(--opacity-disabled);
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

	.meta,
	.status {
		color: var(--auth-body);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.status {
		color: var(--color-warning);
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
</style>
