<!-- Approved draft A18d / A18m · Accounts list. -->
<script lang="ts">
	import Search from '@lucide/svelte/icons/search';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import { page } from '$app/state';
	import Badge from '#lib/ui/admin/Badge.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import { ACCOUNT_STATUS_LABELS, ACCOUNT_TONES, initials, when, withQuery } from '#lib/admin.js';
	import { PIN_LABELS, accountSummary, networksLabel, plural } from '#lib/admin-networks.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	const counts = $derived(data.page.counts);
	const rows = $derived(data.page.items);
	const statuses = ['active', 'restricted', 'suspended', 'deactivated'] as const;
	const filters = $derived([
		{ status: null, label: `All · ${counts.all ?? 0}` },
		...statuses.map((s) => ({
			status: s,
			label: `${ACCOUNT_STATUS_LABELS[s]} · ${counts[s] ?? 0}`
		}))
	]);
	const filterHref = (status: string | null) =>
		withQuery(page.url, { status, cursor: null, q: data.q || null });
</script>

<div class="admin-page">
	<RootHero
		pose="admin-accounts"
		headingLevel={2}
		title={plural(counts.all ?? 0, 'account')}
		lead={accountSummary(counts)}
	/>

	<div class="admin-filters">
		<form class="admin-search" method="GET" role="search">
			<Search size={16} aria-hidden="true" />
			<input
				type="search"
				name="q"
				value={data.q}
				placeholder="Search name, UID, email or phone"
				aria-label="Search name, UID, email or phone"
				maxlength="100"
			/>
			{#if data.status}<input type="hidden" name="status" value={data.status} />{/if}
		</form>
		<nav class="segmented" aria-label="Filter by status">
			{#each filters as f (f.status ?? 'all')}
				<a
					href={filterHref(f.status)}
					aria-current={data.status === f.status ? 'page' : undefined}
					data-sveltekit-noscroll>{f.label}</a
				>
			{/each}
		</nav>
	</div>

	<section class="admin-card" aria-label="Accounts">
		{#if rows.length === 0}
			<p class="admin-empty">{data.q || data.status ? 'No accounts match.' : 'No accounts yet.'}</p>
		{:else}
			<table class="admin-table collapse">
				<thead>
					<tr>
						<th>Account</th>
						<th class="w-status">Status</th>
						<th class="w-net">Network</th>
						<th class="w-seen">Last sign-in</th>
						<th class="num w-pin">PIN</th>
						<th class="w-chev"><span class="sr-only">Open</span></th>
					</tr>
				</thead>
				<tbody>
					{#each rows as a (a.uid)}
						<tr>
							<td>
								<a class="who row-link stretch" href={`/admin/accounts/${a.uid}`}>
									<span class="tile">{initials(a.name)}</span>
									<span class="who-text">
										<span class="who-name">{a.name ?? a.uid}</span>
										<span class="who-sub">{a.uid}{a.email ? ` · ${a.email}` : ''}</span>
									</span>
								</a>
							</td>
							<td data-label="Status">
								<Badge tone={ACCOUNT_TONES[a.status]}>{ACCOUNT_STATUS_LABELS[a.status]}</Badge>
							</td>
							<td data-label="Network">{networksLabel(a.networks)}</td>
							<td data-label="Last sign-in">{when(a.lastSignInAt)}</td>
							<td class="num" class:locked={a.pin === 'locked'} data-label="PIN"
								>{PIN_LABELS[a.pin]}</td
							>
							<td class="chev"><ChevronRight size={16} aria-hidden="true" /></td>
						</tr>
					{/each}
				</tbody>
			</table>
		{/if}
	</section>

	{#if data.page.nextCursor || data.paged}
		<div class="admin-more">
			{#if data.paged}<a class="btn small" href={withQuery(page.url, { cursor: null })}
					>First page</a
				>{/if}
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
	.w-net {
		width: 190px;
	}
	.w-seen {
		width: 160px;
	}
	.w-pin {
		width: 90px;
	}
	.w-chev {
		width: 36px;
	}
	.locked {
		color: var(--color-danger);
	}
	.chev {
		padding-left: 0;
		color: var(--color-muted);
	}
	tbody tr {
		position: relative;
	}
	.stretch::after {
		content: '';
		position: absolute;
		inset: 0;
	}
	.admin-more {
		gap: 12px;
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}
	@media (max-width: 1023px) {
		.chev {
			display: none !important;
		}
	}
</style>
