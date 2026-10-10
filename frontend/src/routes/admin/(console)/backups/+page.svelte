<!-- Paper "Admin — Screens v1" A15 / A16 · Backups & restores. -->
<script lang="ts">
	import Badge from '#lib/ui/admin/Badge.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import type { RestoreRow, RestoreStatus } from '#lib/contract/admin.js';
	import { OPEN_RESTORE, RESTORE_LABELS, RESTORE_TONES } from '#lib/admin.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();

	const open = $derived(data.restores.filter((r) => OPEN_RESTORE.has(r.status)).length);
	const title = $derived(
		open === 0
			? 'No restore requests open'
			: `${open} restore ${open === 1 ? 'request' : 'requests'} open`
	);

	const short = new Intl.DateTimeFormat('en-GB', {
		day: 'numeric',
		month: 'short',
		timeZone: 'Africa/Lagos'
	});
	const long = new Intl.DateTimeFormat('en-GB', {
		day: 'numeric',
		month: 'short',
		year: 'numeric',
		timeZone: 'Africa/Lagos'
	});
	const thisYear = new Date().getFullYear();
	const date = (iso: string | null) => {
		if (!iso) return '—';
		const at = new Date(iso);
		return (at.getFullYear() === thisYear ? short : long).format(at);
	};

	type StepState = 'done' | 'current' | 'todo';
	const STEPS = ['Validate', 'Review diff', 'Restore'] as const;
	/** Where each status sits on Validate → Review diff → Restore. */
	function steps(status: RestoreStatus): StepState[] {
		switch (status) {
			case 'requested':
			case 'validating':
				return ['current', 'todo', 'todo'];
			case 'in_review':
				return ['done', 'current', 'todo'];
			case 'restoring':
				return ['done', 'done', 'current'];
			case 'completed':
				return ['done', 'done', 'done'];
			default:
				return ['todo', 'todo', 'todo'];
		}
	}

	const who = (r: RestoreRow) => r.requestedBy?.name ?? r.requestedBy?.uid ?? 'Former member';
	const PLATFORM = [
		['Schedule', 'Not configured'],
		['Retention', 'Not configured'],
		['Off-platform copy', 'Not configured'],
		['RPO / RTO targets', 'Not set'],
		['Last restore drill', 'Never run'],
		['Storage files', 'Not configured']
	] as const;
</script>

{#snippet trailing(r: RestoreRow)}
	{#if r.status === 'in_review'}
		<a class="btn primary review" href={`/admin/backups/${r.restoreId}`}>Review diff</a>
	{:else if r.status === 'requested'}
		<a class="btn small" href={`/admin/backups/${r.restoreId}`}>Open</a>
	{:else if r.status === 'validating'}
		<span class="progressing">Validating…</span>
	{:else if r.status === 'restoring'}
		<span class="progressing">Restoring…</span>
	{:else if r.status === 'completed'}
		<Badge tone="success">Completed {date(r.finishedAt ?? r.updatedAt)}</Badge>
	{:else}
		<Badge tone={RESTORE_TONES[r.status]}>{RESTORE_LABELS[r.status]}</Badge>
	{/if}
{/snippet}

<div class="admin-page">
	<RootHero
		pose="admin-backups"
		{title}
		lead="Restores are reviewed. History is never overwritten."
	/>

	<section class="admin-section" aria-labelledby="platform-backups">
		<div class="admin-section-head">
			<h2 id="platform-backups">Platform backups</h2>
			<p>From recorded jobs only</p>
		</div>
		<div class="platform">
			<div class="admin-card db">
				<p class="label">Database backups</p>
				<p class="db-value">Managed by Supabase</p>
			</div>
			<dl class="unset">
				{#each PLATFORM as [label, value] (label)}
					<div>
						<dt>{label}</dt>
						<dd>{value}</dd>
					</div>
				{/each}
			</dl>
		</div>
	</section>

	<section class="admin-section" aria-labelledby="restore-requests">
		<div class="admin-section-head">
			<h2 id="restore-requests">Tenant restore requests</h2>
			<p>Only Elivate reviews and restores</p>
		</div>
		<div class="admin-card">
			{#if data.restores.length === 0}
				<p class="admin-empty">No restore requests yet.</p>
			{:else}
				<table class="admin-table requests">
					<thead>
						<tr>
							<th class="c-request">Request</th>
							<th class="c-archive">Archive</th>
							<th>Progress</th>
							<th class="c-end"><span class="sr-only">Status</span></th>
						</tr>
					</thead>
					<tbody>
						{#each data.restores as r (r.restoreId)}
							<tr>
								<td class="c-request">
									<a class="row-link request" href={`/admin/backups/${r.restoreId}`}>
										<span class="request-top">
											<span class="who-name">{r.network ?? 'Network'}</span>
											<span class="ref">{r.reference}</span>
										</span>
										<span class="who-sub">{who(r)} · {date(r.createdAt)}</span>
									</a>
								</td>
								<td class="c-archive archive">Team Vault archive · {date(r.backup.readyAt)}</td>
								<td>
									<ol class="stepper" aria-label={RESTORE_LABELS[r.status]}>
										{#each steps(r.status) as state, i (i)}
											{#if i > 0}<li class="rule" aria-hidden="true"></li>{/if}
											<li class="step {state}">
												<span class="mark" aria-hidden="true">
													{#if state === 'done'}
														<svg width="10" height="10" viewBox="0 0 12 12"
															><path
																d="M2.5 6.2 5 8.5l4.5-5"
																fill="none"
																stroke="currentColor"
																stroke-width="1.8"
																stroke-linecap="round"
																stroke-linejoin="round"
															/></svg
														>
													{:else if state === 'current'}<span class="pip"></span>{/if}
												</span>
												{STEPS[i]}
											</li>
										{/each}
									</ol>
								</td>
								<td class="c-end end">{@render trailing(r)}</td>
							</tr>
						{/each}
					</tbody>
				</table>

				<ul class="cards">
					{#each data.restores as r (r.restoreId)}
						<li>
							<div class="card-top">
								<a class="row-link request" href={`/admin/backups/${r.restoreId}`}>
									<span class="who-name">{r.network ?? 'Network'}</span>
									<span class="who-sub"
										>{r.reference} · {r.status === 'completed'
											? `Completed ${date(r.finishedAt ?? r.updatedAt)}`
											: RESTORE_LABELS[r.status]}</span
									>
								</a>
								{#if r.status === 'in_review'}
									<a class="btn primary small" href={`/admin/backups/${r.restoreId}`}>Review</a>
								{/if}
							</div>
							<div class="bars" aria-hidden="true">
								{#each steps(r.status) as state, i (i)}<span class="bar {state}"></span>{/each}
							</div>
						</li>
					{/each}
				</ul>
			{/if}
		</div>
	</section>
</div>

<style>
	.platform {
		display: flex;
		gap: 16px;
	}
	.db {
		flex: 1.3 1 0;
		gap: 14px;
		padding: 20px 24px;
	}
	.label {
		margin: 0;
		font-size: 13px;
		line-height: 18px;
		color: var(--color-muted);
	}
	.db-value {
		margin: 0;
		font-size: 24px;
		font-weight: 600;
		letter-spacing: -0.01em;
		line-height: 28px;
		color: var(--color-text);
	}
	.unset {
		display: grid;
		flex: 2 1 0;
		grid-template-columns: repeat(3, minmax(0, 1fr));
		margin: 0;
		border: 1px dashed color-mix(in oklab, var(--color-border) 100%, transparent);
		border-radius: 18px;
		overflow: clip;
	}
	.unset > div {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 18px 20px;
		border-right: 1px dashed color-mix(in oklab, var(--color-border) 70%, transparent);
		border-bottom: 1px dashed color-mix(in oklab, var(--color-border) 70%, transparent);
	}
	.unset > div:nth-child(3n) {
		border-right: 0;
	}
	.unset > div:nth-child(n + 4) {
		border-bottom: 0;
	}
	.unset dt {
		font-size: 13px;
		line-height: 16px;
		color: var(--color-muted);
	}
	.unset dd {
		margin: 0;
		font-size: 15px;
		font-weight: 500;
		line-height: 20px;
		color: color-mix(in oklab, var(--color-muted) 75%, var(--color-canvas));
	}

	.requests td {
		height: 72px;
	}
	.c-request {
		width: 220px;
	}
	.c-archive {
		width: 200px;
	}
	.c-end {
		width: 150px;
		text-align: right;
	}
	.request {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}
	.request-top {
		display: flex;
		align-items: center;
		gap: 8px;
		white-space: nowrap;
	}
	.ref {
		font-family: var(--font-mono);
		font-size: 11px;
		line-height: 14px;
		color: color-mix(in oklab, var(--color-muted) 80%, var(--color-canvas));
	}
	.archive {
		font-size: 13px;
		line-height: 16px;
	}
	.stepper {
		display: flex;
		align-items: center;
		gap: 8px;
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.step {
		display: flex;
		align-items: center;
		gap: 6px;
		font-size: 12px;
		line-height: 16px;
		white-space: nowrap;
		color: color-mix(in oklab, var(--color-muted) 80%, var(--color-canvas));
	}
	.step.done {
		color: color-mix(in oklab, var(--color-text) 88%, var(--color-muted));
	}
	.step.current {
		color: var(--color-text);
	}
	.mark {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 20px;
		height: 20px;
		border-radius: 999px;
		border: 1.5px solid color-mix(in oklab, var(--color-border) 100%, var(--color-muted) 15%);
	}
	.done .mark {
		border: 1px solid color-mix(in oklab, var(--color-success) 40%, transparent);
		background: color-mix(in oklab, var(--color-success) 16%, var(--color-surface));
		color: var(--color-success);
	}
	.current .mark {
		border-color: var(--color-accent);
	}
	.pip {
		width: 8px;
		height: 8px;
		border-radius: 999px;
		background: var(--color-accent);
	}
	.rule {
		flex-shrink: 0;
		width: 16px;
		height: 1px;
		background: var(--color-border);
	}
	.end {
		white-space: nowrap;
	}
	.progressing {
		font-size: 13px;
		line-height: 16px;
		color: var(--color-muted);
	}
	.review {
		min-height: 40px;
	}
	.cards {
		display: none;
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}

	@media (max-width: 1023px) {
		.platform {
			flex-direction: column;
			gap: 0;
			border: 1px solid color-mix(in oklab, var(--color-border) 70%, transparent);
			border-radius: 18px;
			background: var(--color-surface);
			overflow: clip;
		}
		.db {
			gap: 8px;
			padding: 16px;
			border: 0;
			border-radius: 0;
		}
		.db-value {
			font-size: 20px;
			line-height: 26px;
		}
		.unset {
			display: block;
			border: 0;
			border-radius: 0;
		}
		.unset > div,
		.unset > div:nth-child(n + 4) {
			flex-direction: row;
			align-items: center;
			justify-content: space-between;
			min-height: 43px;
			padding: 0 16px;
			border: 0;
			border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
		}
		.unset dt {
			font-size: 13px;
			color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
		}
		.unset dd {
			font-size: 13px;
			font-weight: 400;
		}
		.requests {
			display: none;
		}
		.cards {
			display: block;
		}
		.cards li {
			display: flex;
			flex-direction: column;
			gap: 12px;
			padding: 14px 16px;
			border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
		}
		.cards li:first-child {
			border-top: 0;
		}
		.card-top {
			display: flex;
			align-items: center;
			justify-content: space-between;
			gap: 12px;
		}
		.bars {
			display: grid;
			grid-template-columns: repeat(3, minmax(0, 1fr));
			gap: 4px;
		}
		.bar {
			height: 4px;
			border-radius: 999px;
			background: var(--color-raised);
		}
		.bar.done {
			background: var(--color-success);
		}
		.bar.current {
			background: var(--color-accent);
		}
	}
</style>
