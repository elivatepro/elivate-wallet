<!--
	Approved drafts A22d / A22m · Founder applications (Blueprint 19): Waiting,
	Approved and Not approved tabs; A22b review dialog (approve or not
	approved, reason, PIN). Approved rows not yet accepted can be resent.
-->
<script lang="ts">
	import { page } from '$app/state';
	import AdminDialog from '#lib/ui/admin/AdminDialog.svelte';
	import Badge from '#lib/ui/admin/Badge.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import { FOUNDER_RANK_LABELS } from '#lib/contract/founders.js';
	import type { FounderApplication } from '#lib/contract/admin.js';
	import { day, initials, when, withQuery } from '#lib/admin.js';
	import { formatPhone } from '#lib/founders.js';
	import { plural } from '#lib/ui/admin/MiscText.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	type FormState = { error?: string; reason?: string; key?: string; decision?: string };
	const fv = $derived(form as FormState | null | undefined);
	// The submit label follows the chosen decision (A22b: "Approve").
	let choice = $derived<'approve' | 'reject'>(fv?.decision === 'reject' ? 'reject' : 'approve');

	const counts = $derived(data.applications.counts);
	const rows = $derived(data.applications.items);
	const waiting = $derived(counts.waiting ?? 0);
	const tabs = [
		{ status: 'waiting', label: 'Waiting' },
		{ status: 'approved', label: 'Approved' },
		{ status: 'rejected', label: 'Not approved' }
	] as const;
	const tabHref = (status: string) =>
		withQuery(page.url, { status: status === 'waiting' ? null : status, cursor: null });

	const dialog = $derived(page.url.searchParams.get('dialog'));
	const selected = $derived(rows.find((r) => r.applicationId === page.url.searchParams.get('id')));
	const reviewing = $derived(
		dialog === 'review' && selected?.status === 'waiting' ? selected : null
	);
	const resending = $derived(dialog === 'resend' && selected ? selected : null);
	const closeHref = $derived(withQuery(page.url, { dialog: null, id: null }));

	const applied = (a: FounderApplication) =>
		`${when(a.createdAt)} · ${a.earlierApplications === 0 ? 'first application' : `applied ${plural(a.earlierApplications + 1, 'time')}`}`;

	function invitationLabel(a: FounderApplication): {
		text: string;
		tone: 'success' | 'warning' | 'neutral';
	} {
		const inv = a.invitation;
		if (!inv) return { text: '—', tone: 'neutral' };
		if (inv.status === 'accepted') return { text: 'Accepted', tone: 'success' };
		if (inv.status === 'expired') return { text: 'Link expired', tone: 'warning' };
		return { text: `Sent · until ${day(inv.expiresAt)}`, tone: 'neutral' };
	}
	const canResend = (a: FounderApplication) =>
		a.status === 'approved' && a.invitation !== null && a.invitation.status !== 'accepted';
</script>

<div class="admin-page">
	<RootHero
		pose="admin-applications"
		headingLevel={2}
		title={waiting === 0
			? 'No founder applications waiting'
			: `${plural(waiting, 'founder application')} waiting`}
		lead="Approve Ruby Director 4 and above. Approval emails a founder invitation."
	/>

	<nav class="segmented chips" aria-label="Filter by status">
		{#each tabs as t (t.status)}
			<a
				href={tabHref(t.status)}
				aria-current={data.status === t.status ? 'page' : undefined}
				data-sveltekit-noscroll
				>{t.label}{#if t.status === 'waiting' && waiting > 0}<span class="count">{waiting}</span
					>{/if}</a
			>
		{/each}
	</nav>

	<section class="admin-card" aria-label="Founder applications">
		{#if rows.length === 0}
			<p class="admin-empty">
				{data.status === 'waiting'
					? 'Nothing to review.'
					: data.status === 'approved'
						? 'No approved applications yet.'
						: 'No applications turned down.'}
			</p>
		{:else}
			<table class="admin-table collapse">
				<thead>
					<tr>
						<th>Applicant</th>
						<th class="w-team">Team name</th>
						<th class="w-rank">Rank</th>
						{#if data.status === 'waiting'}
							<th class="w-phone">Phone</th>
							<th class="num w-when">Applied</th>
						{:else}
							<th class="w-phone">{data.status === 'approved' ? 'Invitation' : 'Decided by'}</th>
							<th class="num w-when">Decided</th>
						{/if}
						<th class="w-action"><span class="sr-only">Action</span></th>
					</tr>
				</thead>
				<tbody>
					{#each rows as a (a.applicationId)}
						<tr>
							<td>
								<span class="who">
									<span class="tile">{initials(a.fullName)}</span>
									<span class="who-text">
										<span class="who-name">{a.fullName}</span>
										<span class="who-sub">{a.email}</span>
									</span>
								</span>
							</td>
							<td data-label="Team">{a.teamName}</td>
							<td data-label="Rank">{FOUNDER_RANK_LABELS[a.rank]}</td>
							{#if data.status === 'waiting'}
								<td class="mono" data-label="Phone">{formatPhone(a.phone)}</td>
								<td class="num" data-label="Applied">{when(a.createdAt)}</td>
							{:else if data.status === 'approved'}
								{@const inv = invitationLabel(a)}
								<td data-label="Invitation"><Badge tone={inv.tone}>{inv.text}</Badge></td>
								<td class="num" data-label="Decided">{when(a.decidedAt)}</td>
							{:else}
								<td data-label="Decided by">{a.decidedBy?.name ?? a.decidedBy?.uid ?? '—'}</td>
								<td class="num" data-label="Decided">{when(a.decidedAt)}</td>
							{/if}
							<td class="num">
								{#if a.status === 'waiting'}
									<a
										class="btn small"
										href={withQuery(page.url, { dialog: 'review', id: a.applicationId })}>Review</a
									>
								{:else if canResend(a)}
									<a
										class="btn small"
										href={withQuery(page.url, { dialog: 'resend', id: a.applicationId })}
										>Resend invitation</a
									>
								{/if}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		{/if}
	</section>

	{#if data.applications.nextCursor || data.paged}
		<div class="admin-more">
			{#if data.paged}
				<a class="btn small" href={withQuery(page.url, { cursor: null })}>First page</a>
			{/if}
			{#if data.applications.nextCursor}
				<a class="btn small" href={withQuery(page.url, { cursor: data.applications.nextCursor })}
					>Load more</a
				>
			{/if}
		</div>
	{/if}
</div>

{#if reviewing}
	<AdminDialog
		pose="admin-application-review"
		title="Review application"
		lead={`${reviewing.fullName} · ${reviewing.teamName}`}
		action="?/decide"
		cancelHref={closeHref}
		submitLabel={choice === 'reject' ? 'Save decision' : 'Approve'}
		idempotencyKey={fv?.key ?? data.idempotencyKey}
		error={fv?.error ?? null}
		reason={fv?.reason ?? ''}
	>
		<input type="hidden" name="applicationId" value={reviewing.applicationId} />
		<dl class="facts">
			<div>
				<dt>Rank</dt>
				<dd>{FOUNDER_RANK_LABELS[reviewing.rank]}</dd>
			</div>
			<div>
				<dt>Email</dt>
				<dd>{reviewing.email}</dd>
			</div>
			<div>
				<dt>Phone</dt>
				<dd class="mono">{formatPhone(reviewing.phone)}</dd>
			</div>
			<div>
				<dt>Applied</dt>
				<dd>{applied(reviewing)}</dd>
			</div>
		</dl>
		<fieldset class="choice">
			<legend class="sr-only">Decision</legend>
			<label class="option">
				<input type="radio" name="decision" value="approve" bind:group={choice} />
				Approve · email a founder invitation
			</label>
			<label class="option">
				<input type="radio" name="decision" value="reject" bind:group={choice} />
				Not approved · they can apply again after 30 days
			</label>
		</fieldset>
	</AdminDialog>
{:else if resending}
	<AdminDialog
		pose="admin-application-review"
		title="Resend invitation"
		lead={`${resending.fullName} · ${resending.teamName}`}
		action="?/resend"
		cancelHref={closeHref}
		submitLabel="Resend invitation"
		idempotencyKey={fv?.key ?? data.idempotencyKey}
		error={fv?.error ?? null}
		reason={fv?.reason ?? ''}
	>
		<input type="hidden" name="applicationId" value={resending.applicationId} />
		<p class="note">A new link goes to {resending.email}. The old link stops working.</p>
	</AdminDialog>
{/if}

<style>
	.w-team {
		width: 190px;
	}
	.w-rank {
		width: 170px;
	}
	.w-phone {
		width: 160px;
	}
	.w-when {
		width: 110px;
	}
	.w-action {
		width: 92px;
	}
	.mono {
		font-family: var(--font-mono);
		font-size: 13px;
	}
	.chips {
		align-self: flex-start;
		max-width: 100%;
	}
	.count {
		margin-left: 6px;
		color: var(--color-accent-label);
		font-size: 12px;
	}
	.facts {
		display: flex;
		flex-direction: column;
		gap: 10px;
		margin: 0;
	}
	.facts div {
		display: flex;
		justify-content: space-between;
		gap: 16px;
		font-size: 14px;
	}
	.facts dt {
		color: var(--color-muted);
	}
	.facts dd {
		margin: 0;
		font-weight: var(--font-weight-medium);
		text-align: right;
		overflow-wrap: anywhere;
	}
	.choice {
		display: flex;
		flex-direction: column;
		gap: 10px;
		margin: 0;
		padding: 0;
		border: 0;
	}
	.option {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 48px;
		padding: 0 16px;
		border-radius: 12px;
		border: 1px solid var(--color-border);
		font-size: 14px;
		font-weight: var(--font-weight-medium);
	}
	.option:has(input:checked) {
		background: var(--color-raised);
	}
	.option input {
		accent-color: var(--color-accent);
	}
	.note {
		margin: 0;
		color: var(--color-muted);
		font-size: 14px;
		line-height: 20px;
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}
</style>
