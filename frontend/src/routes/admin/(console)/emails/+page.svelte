<!-- Approved draft A19d / A19m · Failed emails (dead letters) and Requeue (reason + PIN). -->
<script lang="ts">
	import { page } from '$app/state';
	import AdminDialog from '#lib/ui/admin/AdminDialog.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import { actionLabel, when, withQuery } from '#lib/admin.js';
	import { plural } from '#lib/ui/admin/MiscText.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	type FormState = { error?: string; reason?: string; key?: string };
	const fv = $derived(form as FormState | null | undefined);
	/** money.income_posted → "Income posted"; invitation.issued → "Invitation issued". */
	const templateName = (key: string) => {
		const [group, ...rest] = key.split('.');
		return actionLabel(
			rest.length > 0 && group !== 'money' && group !== 'account' ? key : rest.join(' ') || key
		);
	};
	const tileOf = (key: string) => (key.split('.')[0] ?? '?').slice(0, 3).toUpperCase();
	const requeueing = $derived(
		page.url.searchParams.get('dialog') === 'requeue'
			? data.letters.find((l) => l.eventId === page.url.searchParams.get('id'))
			: undefined
	);
	const closeHref = $derived(withQuery(page.url, { dialog: null, id: null }));
</script>

<div class="admin-page">
	<RootHero
		pose="invitations-manage"
		headingLevel={2}
		title={data.letters.length === 0
			? 'Every email went out'
			: `${plural(data.letters.length, 'email')} didn’t send`}
		lead={data.letters.length === 0
			? 'Nothing is waiting to be sent again.'
			: 'Each was tried until it gave up.'}
	/>

	<section class="admin-card" aria-label="Failed emails">
		{#if data.letters.length === 0}
			<p class="admin-empty">No failed emails.</p>
		{:else}
			<table class="admin-table collapse">
				<thead>
					<tr
						><th>Email</th><th>Last error</th><th>Network</th><th>Failed</th><th class="num"
							>Tries</th
						><th><span class="sr-only">Requeue</span></th></tr
					>
				</thead>
				<tbody>
					{#each data.letters as l (l.eventId)}
						<tr>
							<td>
								<span class="who">
									<span class="tile">{tileOf(l.template)}</span>
									<span class="who-text">
										<span class="who-name">{templateName(l.template)}</span>
										<span class="who-sub"
											>Event {l.eventId.slice(0, 4)}…{l.eventId.slice(-4)} · cycle {l.cycle}</span
										>
									</span>
								</span>
							</td>
							<td data-label="Last error"
								><span class="code">{l.lastErrorCode ?? 'unknown'}</span></td
							>
							<td data-label="Network" class:muted={!l.tenantId}>
								{l.tenantId ? (data.names[l.tenantId] ?? 'Network') : '— (personal)'}
							</td>
							<td data-label="Failed">{when(l.deadLetteredAt)}</td>
							<td class="num" data-label="Tries">{l.attempts} / 8</td>
							<td class="num">
								<a
									class="btn small"
									href={withQuery(page.url, { dialog: 'requeue', id: l.eventId })}>Requeue</a
								>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		{/if}
	</section>
</div>

{#if requeueing}
	<AdminDialog
		pose="invitations-manage"
		title="Send it again?"
		lead={`${templateName(requeueing.template)} · a fresh cycle of tries`}
		action="?/requeue"
		cancelHref={closeHref}
		submitLabel="Requeue"
		idempotencyKey={fv?.key ?? data.idempotencyKey}
		error={fv?.error ?? null}
		reason={fv?.reason ?? ''}
	>
		<input type="hidden" name="eventId" value={requeueing.eventId} />
	</AdminDialog>
{/if}

<style>
	.code {
		display: inline-flex;
		padding: 3px 9px;
		border-radius: 999px;
		background: color-mix(in oklab, var(--color-danger) 14%, var(--color-surface));
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--color-danger);
	}
	.muted {
		color: var(--color-muted);
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}
</style>
