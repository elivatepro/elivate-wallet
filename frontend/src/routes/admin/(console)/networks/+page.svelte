<!-- Paper "Admin — Screens v1" A17d / A17m · Networks list. -->
<script lang="ts">
	import Search from '@lucide/svelte/icons/search';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import { page } from '$app/state';
	import Badge from '#lib/ui/admin/Badge.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import { NETWORK_STATES, NETWORK_STATE_LABELS } from '#lib/contract/admin.js';
	import { NETWORK_TONES, initials, withQuery } from '#lib/admin.js';
	import {
		endsLabel,
		networkSubline,
		networkSummary,
		planLabel,
		plural,
		seatsLabel
	} from '#lib/admin-networks.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	const counts = $derived(data.page.counts);
	const rows = $derived(data.page.items);
	const filters = $derived([
		{ state: null, label: `All · ${counts.all ?? 0}` },
		...NETWORK_STATES.filter((s) => s !== 'deactivated' || (counts.deactivated ?? 0) > 0).map(
			(s) => ({ state: s, label: `${NETWORK_STATE_LABELS[s]} · ${counts[s] ?? 0}` })
		)
	]);
	const filterHref = (state: string | null) =>
		withQuery(page.url, { state, cursor: null, q: data.q || null });
</script>

<div class="admin-page">
	<RootHero
		pose="offices"
		headingLevel={2}
		title={plural(counts.all ?? 0, 'network')}
		lead={networkSummary(counts)}
	/>

	<div class="admin-filters">
		<form class="admin-search" method="GET" role="search">
			<Search size={16} aria-hidden="true" />
			<input
				type="search"
				name="q"
				value={data.q}
				placeholder="Search network or President"
				aria-label="Search network or President"
				maxlength="100"
			/>
			{#if data.state}<input type="hidden" name="state" value={data.state} />{/if}
		</form>
		<nav class="segmented chips" aria-label="Filter by status">
			{#each filters as f (f.state ?? 'all')}
				<a
					href={filterHref(f.state)}
					aria-current={data.state === f.state ? 'page' : undefined}
					data-sveltekit-noscroll>{f.label}</a
				>
			{/each}
		</nav>
	</div>

	<section class="admin-card" aria-label="Networks">
		{#if rows.length === 0}
			<p class="admin-empty">
				{data.q || data.state ? 'No networks match.' : 'No networks yet.'}
			</p>
		{:else}
			<table class="admin-table desktop">
				<thead>
					<tr>
						<th>Network</th>
						<th class="w-status">Status</th>
						<th class="w-plan">Plan</th>
						<th class="w-ends">Ends</th>
						<th class="num w-seats">Seats</th>
						<th class="w-chev"><span class="sr-only">Open</span></th>
					</tr>
				</thead>
				<tbody>
					{#each rows as n (n.tenantId)}
						{@const ends = endsLabel(n)}
						<tr>
							<td>
								<a class="who row-link stretch" href={`/admin/networks/${n.tenantId}`}>
									<span class="tile">{initials(n.name)}</span>
									<span class="who-text">
										<span class="who-name">{n.name}</span>
										<span class="who-sub">{networkSubline(n)}</span>
									</span>
								</a>
							</td>
							<td><Badge tone={NETWORK_TONES[n.state]}>{NETWORK_STATE_LABELS[n.state]}</Badge></td>
							<td class:muted={n.state === 'paused'}>{planLabel(n)}</td>
							<td class:muted={ends.past}>{ends.text}</td>
							<td class="num">{seatsLabel(n)}</td>
							<td class="chev"><ChevronRight size={16} aria-hidden="true" /></td>
						</tr>
					{/each}
				</tbody>
			</table>

			<ul class="cards">
				{#each rows as n (n.tenantId)}
					{@const ends = endsLabel(n)}
					<li>
						<a href={`/admin/networks/${n.tenantId}`}>
							<span class="tile">{initials(n.name)}</span>
							<span class="card-body">
								<span class="card-top">
									<span class="who-text">
										<span class="who-name">{n.name}</span>
										<span class="who-sub">{networkSubline(n)}</span>
									</span>
									<Badge tone={NETWORK_TONES[n.state]}>{NETWORK_STATE_LABELS[n.state]}</Badge>
								</span>
								{#if n.state !== 'pending_payment'}
									<span class="card-meta" class:muted={n.state === 'paused'}>{planLabel(n)}</span>
									<span class="card-foot">
										<span class="card-meta" class:muted={ends.past}
											>{ends.past ? ends.text : `Ends ${ends.text}`}</span
										>
										<strong>{seatsLabel(n)}</strong>
									</span>
								{/if}
							</span>
						</a>
					</li>
				{/each}
			</ul>
		{/if}
	</section>

	{#if data.page.nextCursor || data.paged}
		<div class="admin-more">
			{#if data.paged}
				<a class="btn small" href={withQuery(page.url, { cursor: null })}>First page</a>
			{/if}
			{#if data.page.nextCursor}
				<a class="btn small" href={withQuery(page.url, { cursor: data.page.nextCursor })}
					>Load more</a
				>
			{/if}
		</div>
	{/if}
</div>

<style>
	.w-status {
		width: 150px;
	}
	.w-plan {
		width: 170px;
	}
	.w-ends {
		width: 130px;
	}
	.w-seats {
		width: 100px;
	}
	.w-chev {
		width: 36px;
	}
	.desktop td:not(:first-child) {
		white-space: nowrap;
	}
	.chips {
		max-width: 100%;
	}
	.chev {
		padding-left: 0;
		color: var(--color-muted);
	}
	.desktop tbody tr {
		position: relative;
	}
	/* The whole row opens the network; the name link stretches over it. */
	.stretch::after {
		content: '';
		position: absolute;
		inset: 0;
	}
	.admin-more {
		gap: 12px;
	}
	.cards {
		display: none;
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.cards li + li {
		border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
	}
	.cards a {
		display: flex;
		gap: 12px;
		padding: 16px;
		color: inherit;
		text-decoration: none;
	}
	.card-body {
		display: flex;
		flex: 1 1 auto;
		flex-direction: column;
		gap: 4px;
		min-width: 0;
	}
	.card-top {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: 8px;
		margin-bottom: 6px;
	}
	.card-meta {
		font-size: 13px;
		line-height: 18px;
		color: color-mix(in oklab, var(--color-text) 75%, var(--color-muted));
	}
	.card-meta.muted {
		color: var(--color-muted);
	}
	.card-foot {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 8px;
	}
	.card-foot strong {
		font-size: 13px;
		font-weight: 600;
		font-variant-numeric: tabular-nums;
		color: var(--color-text);
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}
	@media (max-width: 1023px) {
		.desktop {
			display: none;
		}
		.cards {
			display: block;
		}
		.admin-filters {
			flex-direction: column;
			align-items: stretch;
		}
		.admin-filters > :global(*) {
			min-width: 0;
		}
		.chips {
			gap: 8px;
			padding: 0;
			border: 0;
			background: transparent;
			border-radius: 0;
		}
		.chips a {
			padding: 8px 14px;
			border-radius: 999px;
			border: 1px solid color-mix(in oklab, var(--color-border) 70%, transparent);
			background: var(--color-surface);
		}
	}
</style>
