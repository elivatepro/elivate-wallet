<!--
	Audit log, Paper "App — Screens v1" F05 (desktop) / F06 (mobile): the
	President's read-only, network-scoped log (D-11, W-23), newest first, with
	the safe fields only (who, what, when, reason, safe before/after). Selecting
	a row opens its detail. Filters drawn in Paper (who / area / period) need a
	backend filter that does not exist yet, so they are not shown.
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext } from 'svelte';
	import { AppOrgRoutes, AuditEvents, type AuditEvent } from '#lib/contract/org-admin.js';
	import { loadView } from '#lib/client/org.svelte.js';
	import { cachedPage, MorePages } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { auditArea, auditFacts, auditSentence, personName } from '#lib/org.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import OrgHero from '#lib/ui/org/OrgHero.svelte';

	const shell = getContext<Shell>('shell');
	const workspace = $derived(shell.state.kind === 'ready' ? shell.state.view.workspace : null);

	// Blueprint 23: the first page opens from cache, then refreshes.
	const view = cachedPage(shell, {
		kind: 'audit',
		load: () => loadView(AppOrgRoutes.audit, AuditEvents)
	});
	const pages = new MorePages<AuditEvent>(() => view.data);
	const items = $derived(pages.items);
	const nextCursor = $derived(pages.nextCursor);
	const loaded = $derived(view.data !== null);
	const loadError = $derived(view.data ? null : view.error);
	let picked = $state<AuditEvent['id'] | null>(null);
	const selected = $derived(items.find((e) => e.id === picked) ?? items[0] ?? null);

	const loadMore = () =>
		pages.more((cursor) =>
			loadView(`${AppOrgRoutes.audit}?cursor=${encodeURIComponent(cursor)}`, AuditEvents)
		);

	const when = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', {
			day: 'numeric',
			month: 'short',
			hour: '2-digit',
			minute: '2-digit',
			hour12: false
		}).format(new Date(iso));
	const full = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit',
			hour12: false,
			timeZoneName: 'short'
		}).format(new Date(iso));
</script>

<svelte:head><title>Audit log · Elivate Wallet</title></svelte:head>

<div class="o-page">
	<OrgHero
		id="audit-heading"
		pose={null}
		title={loaded
			? `${items.length}${nextCursor ? '+' : ''} ${items.length === 1 ? 'event' : 'events'}`
			: 'Audit log'}
		line="Newest first"
	>
		{#snippet eyebrow()}
			<span class="readonly">Read-only</span><span>{workspace?.tenantName ?? ''}</span>
		{/snippet}
	</OrgHero>

	<CacheNote savedAt={view.savedAt} online={shell.online} failed={view.error !== null} />

	{#if !loaded && !loadError}
		<div class="o-skeleton" aria-hidden="true"></div>
		<p class="visually-hidden" role="status">Loading the audit log</p>
	{:else if loadError}
		<div class="o-error" role="alert">
			<p>{loadError}</p>
			<button type="button" class="o-ghost" onclick={() => view.reload()}>Try again</button>
		</div>
	{:else if items.length === 0}
		<p class="o-card o-empty">Nothing recorded yet.</p>
	{:else}
		<div class="split">
			<section class="o-card log" aria-label="Events">
				<div class="o-cols" aria-hidden="true">
					<span class="c-when">When</span>
					<span class="c-who">Who</span>
					<span class="o-grow">What happened</span>
				</div>
				<ul class="o-rows">
					{#each items as event (event.id)}
						<li>
							<button
								type="button"
								class="o-row event"
								aria-pressed={selected?.id === event.id}
								onclick={() => (picked = event.id)}
							>
								<span class="c-when o-sub">{when(event.at)}</span>
								<span class="c-who o-stack">
									<span class="who">{event.actor ? personName(event.actor) : 'Elivate'}</span>
									<span class="o-sub">{auditArea(event.action)}</span>
								</span>
								<span class="o-grow what">{auditSentence(event)}</span>
							</button>
						</li>
					{/each}
				</ul>
				{#if nextCursor}
					<button
						type="button"
						class="o-ghost more"
						disabled={pages.loading}
						aria-busy={pages.loading}
						onclick={loadMore}>Show more</button
					>
					{#if pages.error}<p class="o-sub" role="alert">{pages.error}</p>{/if}
				{/if}
			</section>

			{#if selected}
				<aside class="o-card detail" aria-label="Event detail">
					<header class="d-head">
						<span class="o-label o-mono eyebrow-d">{auditArea(selected.action)}</span>
						<h2>{auditSentence(selected)}</h2>
					</header>
					<dl>
						<div>
							<dt>By</dt>
							<dd>{selected.actor ? personName(selected.actor) : 'Elivate'}</dd>
						</div>
						<div>
							<dt>When</dt>
							<dd>{full(selected.at)}</dd>
						</div>
						{#if selected.reason}<div>
								<dt>Reason</dt>
								<dd>{selected.reason}</dd>
							</div>{/if}
					</dl>
					{#if auditFacts(selected.before).length || auditFacts(selected.after).length}
						<dl class="facts">
							{#each auditFacts(selected.before) as [key, value] (key)}
								<div>
									<dt>Before · {key}</dt>
									<dd class="before">{value}</dd>
								</div>
							{/each}
							{#each auditFacts(selected.after) as [key, value] (key)}
								<div>
									<dt>After · {key}</dt>
									<dd class="after">{value}</dd>
								</div>
							{/each}
						</dl>
					{/if}
				</aside>
			{/if}
		</div>
	{/if}
</div>

<style>
	.readonly {
		padding: 3px 10px;
		border-radius: var(--radius-pill);
		background: #ffffff1f;
		color: #f2f4f4;
		font-size: 13px;
		white-space: nowrap;
	}

	.split {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.event {
		width: 100%;
		border-top: 0;
		border-right: 0;
		border-left: 0;
		background: transparent;
		font: inherit;
		text-align: left;
		cursor: pointer;
		flex-wrap: wrap;
		row-gap: 4px;
	}

	.event[aria-pressed='true'] {
		background: color-mix(in oklab, var(--color-text) 3%, transparent);
		box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--color-text) 8%, transparent);
	}

	.c-when {
		flex-shrink: 0;
		width: 100%;
	}

	.who {
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
	}

	.what {
		font-size: var(--text-14);
		line-height: 18px;
	}

	.more {
		margin: 12px auto;
		display: flex;
	}

	.detail {
		display: flex;
		flex-direction: column;
	}

	.d-head {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 20px 22px 16px;
		border-bottom: 1px solid var(--o-row);
	}

	.eyebrow-d {
		font-size: 11px;
		text-transform: uppercase;
	}

	h2 {
		font-size: 18px;
		font-weight: var(--font-weight-semibold);
		line-height: 24px;
	}

	dl {
		display: flex;
		flex-direction: column;
		gap: 10px;
		margin: 0;
		padding: 16px 22px;
	}

	dl.facts {
		border-top: 1px solid var(--o-row);
	}

	dl > div {
		display: flex;
		justify-content: space-between;
		gap: 16px;
		font-size: 13px;
	}

	dt {
		color: var(--o-strong);
	}

	dd {
		margin: 0;
		text-align: right;
		overflow-wrap: anywhere;
	}

	.before {
		color: var(--color-muted);
	}

	.after {
		color: var(--color-text);
	}

	@media (min-width: 1024px) {
		.split {
			flex-direction: row;
			align-items: flex-start;
			gap: 16px;
		}

		.log {
			flex: 1;
		}

		.detail {
			position: sticky;
			top: 24px;
			flex-shrink: 0;
			width: 360px;
		}

		.event {
			flex-wrap: nowrap;
			height: 60px;
		}

		.c-when {
			width: 110px;
		}

		.c-who {
			flex-shrink: 0;
			width: 164px;
		}
	}
</style>
