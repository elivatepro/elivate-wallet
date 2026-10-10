<!-- Paper "Admin — Screens v1" A15rd / A15rm · Restore review (guided manual restore, Q7). -->
<script lang="ts">
	import { page } from '$app/state';
	import AdminDialog from '#lib/ui/admin/AdminDialog.svelte';
	import Badge from '#lib/ui/admin/Badge.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import type { Difference } from '#lib/contract/admin.js';
	import { RESTORE_LABELS, RESTORE_TONES, sectionLabel, when } from '#lib/admin.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	const r = $derived(data.restore);

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
	const n = (value: number) => value.toLocaleString('en-GB');

	const network = $derived(r.network ?? 'Network');
	const requester = $derived(r.requestedBy?.name ?? r.requestedBy?.uid ?? 'A former member');

	const FAIL_TEXT: Readonly<Record<string, string>> = {
		archive_missing: 'The archive file is missing',
		archive_checksum_mismatch: 'The archive’s SHA-256 doesn’t match',
		file_checksum_mismatch: 'A file’s SHA-256 doesn’t match the manifest',
		row_count_mismatch: 'Row counts don’t match the manifest',
		archive_unreadable: 'The archive can’t be read'
	};

	function changes(d: Difference): string {
		const parts: string[] = [];
		if (d.changed > 0) parts.push(`${n(d.changed)} changed`);
		if (d.added > 0) parts.push(`${n(d.added)} added since`);
		if (d.removed > 0) parts.push(`${n(d.removed)} removed`);
		return parts.length ? parts.join(' · ') : 'No changes';
	}
	const touched = (d: Difference) => d.changed + d.added + d.removed > 0;

	const DIALOGS = {
		start: {
			title: 'Start validating?',
			submit: 'Start validating',
			status: 'validating',
			tone: 'primary',
			reasonLabel: 'Reason'
		},
		fail: {
			title: 'Mark this restore failed?',
			submit: 'Mark failed',
			status: 'failed',
			tone: 'danger',
			reasonLabel: 'Reason'
		},
		reject: {
			title: 'Reject this restore?',
			submit: 'Reject',
			status: 'rejected',
			tone: 'danger',
			reasonLabel: 'Reason'
		},
		restore: {
			title: 'Start restoring?',
			submit: 'Start restoring',
			status: 'restoring',
			tone: 'primary',
			reasonLabel: 'Reason'
		},
		complete: {
			title: 'Mark completed?',
			submit: 'Mark completed',
			status: 'completed',
			tone: 'primary',
			reasonLabel: 'Notes'
		}
	} as const;

	const here = $derived(`/admin/backups/${r.restoreId}`);
	const dialog = $derived(data.dialog ? DIALOGS[data.dialog] : null);
	const failure = $derived(form && 'error' in form ? (form.error as string) : null);
	const kept = $derived(form && 'reason' in form ? String(form.reason ?? '') : '');
</script>

<div class="admin-page">
	<RootHero
		pose="admin-restore"
		title={`${network} restore`}
		lead={`${requester} asked on ${date(r.createdAt)} · Team Vault archive from ${date(r.backup.readyAt)}`}
	/>

	<div class="summary">
		<section class="admin-card note" aria-labelledby="team-reason">
			<h2 id="team-reason" class="label">The team’s reason</h2>
			<p class="body">{r.reason}</p>
		</section>
		<section class="admin-card note" aria-labelledby="validation">
			<div class="note-head">
				<h2 id="validation" class="label">Validation</h2>
				{#if r.validation}
					<Badge tone={r.validation.ok ? 'success' : 'danger'}
						>{r.validation.ok ? 'Passed' : 'Failed'}</Badge
					>
				{/if}
			</div>
			{#if !r.validation}
				<p class="body muted">Not validated yet</p>
			{:else if r.validation.ok}
				<p class="body">
					{n(r.validation.files)} files · every SHA-256 matches · {n(r.validation.rows)} rows reconcile
					with the manifest
				</p>
			{:else}
				<p class="body">
					{FAIL_TEXT[r.validation.failReason ?? ''] ?? 'The archive didn’t pass'} · {n(
						r.validation.files
					)} files · {n(r.validation.rows)} rows
				</p>
			{/if}
		</section>
	</div>

	{#if r.differences}
		<section class="admin-section" aria-labelledby="differences">
			<div class="admin-section-head">
				<h2 id="differences">Differences</h2>
				<p>Archive from {date(r.backup.readyAt)} compared with now</p>
			</div>
			<div class="admin-card">
				{#if r.differences.length === 0}
					<p class="admin-empty">Nothing to compare.</p>
				{:else}
					<table class="admin-table diff">
						<thead>
							<tr>
								<th>Section</th>
								<th class="num c-count">Archive</th>
								<th class="num c-count">Now</th>
								<th class="c-changes">Changes</th>
								<th class="c-restore">On restore</th>
							</tr>
						</thead>
						<tbody>
							{#each r.differences as d (d.section)}
								<tr>
									<td class="section">{sectionLabel(d.section)}</td>
									<td class="num c-count">{n(d.archive)}</td>
									<td class="num c-count">{n(d.now)}</td>
									<td class="c-changes changes" class:warn={d.onRestore === 'manual' && touched(d)}
										>{changes(d)}</td
									>
									<td class="c-restore">
										{#if d.onRestore === 'manual'}
											<Badge tone="info">Fixed by Elivate</Badge>
										{:else}
											<Badge tone="neutral">Kept · never overwritten</Badge>
										{/if}
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				{/if}
			</div>
		</section>
	{/if}

	{#if r.events.length > 0}
		<section class="admin-section" aria-labelledby="history">
			<div class="admin-section-head"><h2 id="history">History</h2></div>
			<ol class="events">
				{#each r.events as e, i (i)}
					<li>
						<span class="dot" aria-hidden="true"></span>
						<span class="event-text">
							<span class="event-top">
								<span class="event-to"
									>{RESTORE_LABELS[e.to as keyof typeof RESTORE_LABELS] ?? e.to}</span
								>
								<span class="event-meta"
									>{e.actor?.name ?? e.actor?.uid ?? 'Elivate'} · {when(e.at)}</span
								>
							</span>
							{#if e.reason}<span class="event-reason">{e.reason}</span>{/if}
						</span>
					</li>
				{/each}
			</ol>
		</section>
	{/if}

	<div class="admin-card actions">
		<div class="state">
			<Badge tone={RESTORE_TONES[r.status]}>{RESTORE_LABELS[r.status]}</Badge>
			{#if data.notice}
				<p class="notice" role="status">{data.notice}</p>
			{:else if r.status === 'in_review' || r.status === 'restoring'}
				<p>Fixes are made by hand, then completed with notes.</p>
			{:else if r.status === 'completed' || r.status === 'rejected' || r.status === 'failed' || r.status === 'cancelled'}
				<p>{r.statusReason ?? ''}{r.finishedAt ? ` · ${date(r.finishedAt)}` : ''}</p>
			{/if}
		</div>
		{#if r.status === 'requested'}
			<a class="btn primary act" href={`${here}?dialog=start`}>Start validating</a>
		{:else if r.status === 'validating'}
			<a class="btn act" href={`${here}?dialog=fail`}>Mark failed</a>
			<form method="POST" action="?/validate">
				<button class="btn primary act" type="submit">Run validation</button>
			</form>
		{:else if r.status === 'in_review'}
			<a class="btn act" href={`${here}?dialog=reject`}>Reject</a>
			<a class="btn primary act" href={`${here}?dialog=restore`}>Start restoring</a>
		{:else if r.status === 'restoring'}
			<a class="btn act" href={`${here}?dialog=fail`}>Mark failed</a>
			<a class="btn primary act" href={`${here}?dialog=complete`}>Mark completed</a>
		{/if}
	</div>
</div>

{#if dialog && data.dialog}
	<AdminDialog
		pose="admin-restore"
		title={dialog.title}
		lead={`${network} · ${r.reference}`}
		action={`?dialog=${data.dialog}&/advance`}
		cancelHref={here}
		submitLabel={dialog.submit}
		tone={dialog.tone}
		idempotencyKey={data.idempotencyKey}
		error={failure}
		reason={kept}
		reasonLabel={dialog.reasonLabel}
	>
		<input type="hidden" name="status" value={dialog.status} />
	</AdminDialog>
{/if}

<svelte:head>
	{#if page.url.searchParams.has('dialog')}<meta name="robots" content="noindex" />{/if}
</svelte:head>

<style>
	.summary {
		display: flex;
		gap: 16px;
	}
	.note {
		flex: 1 1 0;
		gap: 10px;
		padding: 20px 24px;
	}
	.note-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
	}
	.admin-card .label {
		margin: 0;
		font-size: 13px;
		font-weight: 400;
		line-height: 18px;
		color: var(--color-muted);
	}
	.body {
		margin: 0;
		font-size: 15px;
		line-height: 22px;
		color: var(--color-text);
		white-space: pre-line;
	}
	.body.muted {
		color: var(--color-muted);
	}
	.diff td {
		height: 52px;
	}
	.section {
		font-weight: 500;
		color: var(--color-text);
	}
	.c-count {
		width: 106px;
	}
	.c-changes {
		width: 216px;
	}
	.c-restore {
		width: 240px;
	}
	.changes {
		font-size: 13px;
		color: color-mix(in oklab, var(--color-text) 80%, var(--color-muted));
	}
	.changes.warn {
		color: var(--color-warning);
	}
	.events {
		display: flex;
		flex-direction: column;
		gap: 12px;
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.events li {
		display: flex;
		gap: 12px;
	}
	.dot {
		flex-shrink: 0;
		width: 7px;
		height: 7px;
		margin-top: 6px;
		border-radius: 999px;
		background: var(--color-border);
	}
	.event-text {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}
	.event-top {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		font-size: 13px;
		line-height: 18px;
	}
	.event-to {
		font-weight: 500;
		color: var(--color-text);
	}
	.event-meta,
	.event-reason {
		font-size: 12px;
		line-height: 16px;
		color: var(--color-muted);
	}
	.actions {
		flex-direction: row;
		align-items: center;
		gap: 12px;
		padding: 16px 20px;
	}
	.state {
		display: flex;
		flex: 1 1 auto;
		align-items: center;
		gap: 10px;
		min-width: 0;
	}
	.state p {
		margin: 0;
		font-size: 14px;
		line-height: 18px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
	}
	.state .notice {
		color: var(--color-danger);
	}
	.act {
		min-height: 44px;
		padding: 0 20px;
	}
	.actions form {
		display: contents;
	}

	@media (max-width: 1023px) {
		.summary {
			flex-direction: column;
			gap: 16px;
		}
		.note {
			padding: 16px;
		}
		.diff thead {
			display: none;
		}
		.diff,
		.diff tbody {
			display: block;
		}
		.diff tr {
			display: grid;
			grid-template-columns: minmax(0, 1fr) auto;
			grid-template-areas: 'section badge' 'changes counts';
			row-gap: 6px;
			column-gap: 12px;
			padding: 14px 16px;
			border-bottom: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
		}
		.diff tr:last-child {
			border-bottom: 0;
		}
		.diff td {
			height: auto;
			width: auto;
			padding: 0;
			border: 0;
		}
		.diff .section {
			grid-area: section;
			font-size: 15px;
		}
		.diff .c-restore {
			grid-area: badge;
			justify-self: end;
		}
		.diff .changes {
			grid-area: changes;
		}
		/* "5 → 5": the archive and live counts share the last cell. */
		.diff td.c-count {
			grid-area: counts;
			justify-self: end;
			font-size: 12px;
			color: var(--color-muted);
		}
		.diff td.c-count:nth-child(2)::after {
			content: ' →';
		}
		.diff td.c-count:nth-child(2) {
			margin-right: 2.6em;
		}
		.diff td.c-count:nth-child(3) {
			justify-self: end;
		}
		.actions {
			flex-wrap: wrap;
			padding: 16px;
		}
		.state {
			flex-basis: 100%;
		}
		.act {
			flex: 1 1 0;
		}
		.actions form {
			display: flex;
			flex: 1 1 0;
		}
		.actions form .act {
			width: 100%;
		}
	}
</style>
