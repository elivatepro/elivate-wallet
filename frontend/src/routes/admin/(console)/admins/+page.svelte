<!-- Approved draft A20d / A20m · Platform admins (add, remove; reason + PIN). -->
<script lang="ts">
	import Plus from '@lucide/svelte/icons/plus';
	import { page } from '$app/state';
	import AdminDialog from '#lib/ui/admin/AdminDialog.svelte';
	import Badge from '#lib/ui/admin/Badge.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import { day, initials, when, withQuery } from '#lib/admin.js';
	import { plural, shortName } from '#lib/ui/admin/MiscText.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	type FormState = { error?: string; reason?: string; key?: string; targetUid?: string };
	const fv = $derived(form as FormState | null | undefined);
	const dialog = $derived(page.url.searchParams.get('dialog'));
	const removing = $derived(
		dialog === 'remove'
			? data.admins.find((a) => a.uid === page.url.searchParams.get('uid') && !a.isYou)
			: undefined
	);
	const closeHref = $derived(withQuery(page.url, { dialog: null, uid: null }));
</script>

<div class="admin-page">
	<RootHero
		pose="reviewers"
		headingLevel={2}
		title={plural(data.admins.length, 'platform admin')}
		lead="Every admin has full access."
	>
		<a class="btn primary cta" href={withQuery(page.url, { dialog: 'add', uid: null })}>
			<Plus size={16} aria-hidden="true" />Add admin
		</a>
	</RootHero>

	<section class="admin-card" aria-label="Platform admins">
		<table class="admin-table collapse">
			<thead>
				<tr
					><th>Admin</th><th>Status</th><th>Added by</th><th>Added</th><th class="num"
						>Last sign-in</th
					><th><span class="sr-only">Remove</span></th></tr
				>
			</thead>
			<tbody>
				{#each data.admins as a (a.uid)}
					<tr>
						<td>
							<a class="who row-link" href={`/admin/accounts/${a.uid}`}>
								<span class="tile">{initials(a.name)}</span>
								<span class="who-text">
									<span class="who-name">{a.name ?? a.uid}</span>
									<span class="who-sub">{a.uid}{a.isYou ? ' · You' : ''}</span>
								</span>
							</a>
						</td>
						<td data-label="Status"><Badge tone="success">Active</Badge></td>
						<td data-label="Added by" class:muted={!a.grantedBy}>
							{a.grantedBy ? shortName(a.grantedBy.name ?? a.grantedBy.uid) : 'Initial setup'}
						</td>
						<td data-label="Added">{day(a.grantedAt)}</td>
						<td class="num" data-label="Last sign-in">{a.isYou ? 'Now' : when(a.lastSignInAt)}</td>
						<td class="num">
							{#if !a.isYou}
								<a class="btn small" href={withQuery(page.url, { dialog: 'remove', uid: a.uid })}
									>Remove</a
								>
							{/if}
						</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</section>
</div>

{#if dialog === 'add'}
	<AdminDialog
		pose="reviewers"
		title="Add a platform admin"
		lead="They get full access to this site."
		action="?/grant"
		cancelHref={closeHref}
		submitLabel="Add admin"
		idempotencyKey={fv?.key ?? data.idempotencyKey}
		error={fv?.error ?? null}
		reason={fv?.reason ?? ''}
	>
		<label class="uid">
			<span>Wallet UID</span>
			<input
				name="targetUid"
				required
				placeholder="EW-48213"
				value={fv?.targetUid ?? ''}
				autocomplete="off"
			/>
		</label>
	</AdminDialog>
{:else if removing}
	<AdminDialog
		pose="reviewers"
		title="Remove this admin?"
		lead={`${removing.name ?? removing.uid} · ${removing.uid}`}
		action="?/revoke"
		cancelHref={closeHref}
		submitLabel="Remove admin"
		tone="danger"
		idempotencyKey={fv?.key ?? data.idempotencyKey}
		error={fv?.error ?? null}
		reason={fv?.reason ?? ''}
	>
		<input type="hidden" name="targetUid" value={removing.uid} />
	</AdminDialog>
{/if}

<style>
	.cta {
		position: relative;
		align-self: flex-start;
		margin-top: 20px;
		min-height: 46px;
	}
	.muted {
		color: var(--color-muted);
	}
	.uid {
		display: flex;
		flex-direction: column;
		gap: 8px;
		font-size: 14px;
		font-weight: 500;
	}
	.uid input {
		height: 48px;
		padding: 0 16px;
		border-radius: 14px;
		border: 1px solid var(--color-border);
		background: var(--color-canvas);
		font-family: var(--font-mono);
		font-size: 15px;
		color: var(--color-text);
		text-transform: uppercase;
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}
</style>
