<!-- Paper "Admin — Screens v1" A05 / A06 · Search results. -->
<script lang="ts">
	import { page } from '$app/state';
	import SearchIcon from '@lucide/svelte/icons/search';
	import X from '@lucide/svelte/icons/x';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import ArrowDownToLine from '@lucide/svelte/icons/arrow-down-to-line';
	import Receipt from '@lucide/svelte/icons/receipt';
	import Building from '@lucide/svelte/icons/building-2';
	import Landmark from '@lucide/svelte/icons/landmark';
	import Users from '@lucide/svelte/icons/users';
	import Badge from '#lib/ui/admin/Badge.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import { NETWORK_STATE_LABELS, type SearchResults } from '#lib/contract/admin.js';
	import {
		ACCOUNT_STATUS_LABELS,
		ACCOUNT_TONES,
		NETWORK_TONES,
		actionLabel,
		initials,
		withQuery,
		type Tone
	} from '#lib/admin.js';
	import { OFFICE_TYPE_LABELS } from '#lib/org.js';
	import { plural } from '#lib/ui/admin/MiscText.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();

	type Kind = 'person' | 'bank' | 'withdrawal' | 'reference' | 'network' | 'office';
	interface Row {
		key: string;
		href: string;
		kind: Kind;
		tile: string;
		title: string;
		mono: boolean;
		sub: string;
		matched: string;
		network: string;
		networkSub: string;
		status: { label: string; tone: Tone } | null;
	}

	const MATCHED: Readonly<Record<string, string>> = {
		uid: 'UID',
		name: 'Name',
		email: 'Contact',
		phone: 'Contact',
		bank_account: 'Bank account'
	};

	const GOOD = new Set(['active', 'approved', 'completed', 'posted', 'paid', 'verified']);
	const BAD = new Set(['rejected', 'failed', 'deactivated', 'cancelled', 'not_approved']);
	const statusOf = (status: string): { label: string; tone: Tone } => ({
		label: actionLabel(status),
		tone:
			status === 'approved'
				? 'info'
				: GOOD.has(status)
					? 'success'
					: BAD.has(status)
						? 'neutral'
						: 'warning'
	});

	const networkList = (names: readonly string[]) =>
		names.length === 0 ? '—' : names.length === 1 ? names[0]! : `${names[0]} +${names.length - 1}`;

	function rowsOf(r: SearchResults) {
		const byUid = new Map(r.accounts.map((a) => [a.uid, a]));
		const accounts: Row[] = r.accounts
			.filter((a) => a.matchedOn !== 'bank_account')
			.map((a) => ({
				key: `a-${a.uid}`,
				href: `/admin/accounts/${a.uid}`,
				kind: 'person',
				tile: initials(a.name, 'EW'),
				title: a.name ?? a.uid,
				mono: false,
				sub: a.email ? `${a.uid} · ${a.email}` : a.uid,
				matched: MATCHED[a.matchedOn] ?? actionLabel(a.matchedOn),
				network: networkList(a.networks),
				networkSub: '',
				status: { label: ACCOUNT_STATUS_LABELS[a.status], tone: ACCOUNT_TONES[a.status] }
			}));
		const banks: Row[] = r.bankAccounts.map((b, i) => {
			const owner = b.owner ? byUid.get(b.owner.uid) : undefined;
			return {
				key: `b-${i}`,
				href: b.owner ? `/admin/accounts/${b.owner.uid}` : '',
				kind: 'bank',
				tile: '',
				title: `•••• ${b.last4} · ${b.bankName}`,
				mono: false,
				sub: b.owner ? `${b.owner.name ?? b.owner.uid} · ${b.owner.uid}` : '—',
				matched: 'Bank account',
				network: owner ? networkList(owner.networks) : '—',
				networkSub: '',
				status: statusOf(b.status)
			};
		});
		const references: Row[] = r.references.map((ref) => ({
			key: `r-${ref.reference}`,
			href: ref.owner ? `/admin/accounts/${ref.owner.uid}` : `/admin/networks/${ref.tenantId}`,
			kind: ref.kind === 'withdrawal' ? 'withdrawal' : 'reference',
			tile: '',
			title: ref.reference,
			mono: true,
			sub: [actionLabel(ref.kind), ref.owner?.name ?? ref.owner?.uid].filter(Boolean).join(' · '),
			matched: 'Reference',
			network: ref.network ?? '—',
			networkSub: '',
			status: statusOf(ref.status)
		}));
		const networks: Row[] = r.networks.map((n) => ({
			key: `n-${n.tenantId}`,
			href: `/admin/networks/${n.tenantId}`,
			kind: 'network',
			tile: '',
			title: n.name,
			mono: false,
			sub: `${n.shortName} · ${plural(n.officeCount, 'office')}`,
			matched: 'Network name',
			network: n.name,
			networkSub: n.plan?.name ?? '',
			status: { label: NETWORK_STATE_LABELS[n.state], tone: NETWORK_TONES[n.state] }
		}));
		const offices: Row[] = r.offices.map((o) => ({
			key: `o-${o.officeId}`,
			href: `/admin/networks/${o.tenantId}`,
			kind: 'office',
			tile: '',
			title: o.name,
			mono: false,
			sub: OFFICE_TYPE_LABELS[o.type],
			matched: 'Office name',
			network: o.network ?? '—',
			networkSub: '',
			status: statusOf(o.status)
		}));
		return { accounts: [...accounts, ...banks], references, networks, offices };
	}

	const groups = $derived(data.results ? rowsOf(data.results) : null);
	const tabs = $derived(
		groups
			? ([
					{
						key: 'all',
						label: 'All',
						count:
							groups.accounts.length +
							groups.references.length +
							groups.networks.length +
							groups.offices.length
					},
					{ key: 'accounts', label: 'Accounts', count: groups.accounts.length },
					{ key: 'references', label: 'References', count: groups.references.length },
					{ key: 'networks', label: 'Networks', count: groups.networks.length },
					{ key: 'offices', label: 'Offices', count: groups.offices.length }
				] as const)
			: []
	);
	const total = $derived(tabs[0]?.count ?? 0);
	const rows = $derived(
		groups
			? data.tab === 'all'
				? [...groups.accounts, ...groups.references, ...groups.networks, ...groups.offices]
				: groups[data.tab]
			: []
	);
	const shown = $derived(data.results?.query ?? data.q);
	const title = $derived(
		!data.results
			? 'Search the platform'
			: total === 0
				? `No matches for “${shown}”`
				: `${plural(total, 'match', 'matches')} for “${shown}”`
	);
	const lead = 'UID, name, contact, bank account, reference, network or office';
</script>

{#snippet field(id: string)}
	<form class="srch-field" method="GET" action="/admin/search" role="search">
		<label class="sr-only" for={id}>Search the platform</label>
		<SearchIcon size={18} aria-hidden="true" />
		<input
			{id}
			name="q"
			type="search"
			value={data.q}
			minlength="2"
			maxlength="100"
			autocomplete="off"
			spellcheck="false"
			placeholder="Search"
		/>
		{#if data.tab !== 'all'}<input type="hidden" name="tab" value={data.tab} />{/if}
		{#if data.q}
			<a class="clear" href="/admin/search" aria-label="Clear search"><X size={14} /></a>
		{/if}
	</form>
{/snippet}

<div class="admin-page">
	<div class="mobile-field">{@render field('search-q-m')}</div>

	<RootHero pose="no-matches" {title} {lead}>
		<div class="desk-field">{@render field('search-q')}</div>
	</RootHero>

	{#if data.results}
		<nav class="segmented tabs" aria-label="Result type">
			{#each tabs as t (t.key)}
				<a
					href={withQuery(page.url, { tab: t.key === 'all' ? null : t.key })}
					aria-current={data.tab === t.key ? 'page' : undefined}>{t.label} · {t.count}</a
				>
			{/each}
		</nav>

		<section class="admin-card" aria-label="Results">
			{#if rows.length === 0}
				<p class="admin-empty">Nothing here.</p>
			{:else}
				<div class="srch-head" aria-hidden="true">
					<span>Result</span><span>Matched on</span><span>Network</span><span>Status</span><span
					></span>
				</div>
				<ul class="srch-rows">
					{#each rows as r (r.key)}
						<li>
							<a class="srch-row" href={r.href}>
								<span class="who">
									{#if r.kind === 'person'}
										<span class="tile round">{r.tile}</span>
									{:else}
										<span class="tile" aria-hidden="true">
											{#if r.kind === 'withdrawal'}<ArrowDownToLine size={16} />
											{:else if r.kind === 'reference'}<Receipt size={16} />
											{:else if r.kind === 'bank'}<Landmark size={16} />
											{:else if r.kind === 'network'}<Building size={16} />
											{:else}<Users size={16} />{/if}
										</span>
									{/if}
									<span class="who-text">
										<span class="who-name" class:mono={r.mono}>{r.title}</span>
										<span class="who-sub">{r.sub}</span>
									</span>
								</span>
								<span class="matched"
									><span class="pill">{r.matched}</span><span class="m-matched"
										>Matched {r.matched.toLowerCase()}</span
									></span
								>
								<span class="net">
									<span class="net-name">{r.network}</span>
									{#if r.networkSub}<span class="net-sub">{r.networkSub}</span>{/if}
								</span>
								<span class="status"
									>{#if r.status}<Badge tone={r.status.tone}>{r.status.label}</Badge>{/if}</span
								>
								<span class="chev" aria-hidden="true"><ChevronRight size={16} /></span>
							</a>
						</li>
					{/each}
				</ul>
			{/if}
		</section>
	{/if}
</div>

<style>
	.srch-field {
		position: relative;
		display: flex;
		align-items: center;
		gap: 12px;
		width: 620px;
		max-width: 100%;
		height: 52px;
		margin-top: 20px;
		padding: 0 8px 0 18px;
		background: var(--color-canvas);
		border: 1px solid color-mix(in oklab, var(--color-border) 80%, transparent);
		border-radius: 14px;
		color: #d5dadb;
	}
	.srch-field:focus-within {
		border-color: var(--color-accent);
		box-shadow: 0 0 0 3px color-mix(in oklab, var(--color-accent) 20%, transparent);
	}
	.srch-field input {
		flex: 1 1 auto;
		min-width: 0;
		height: 100%;
		border: 0;
		background: transparent;
		font: inherit;
		font-size: 16px;
		line-height: 20px;
		color: var(--color-text);
		outline: none;
	}
	.srch-field input::-webkit-search-cancel-button {
		display: none;
	}
	.clear {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		border-radius: 999px;
		background: var(--color-raised);
		color: var(--color-muted);
	}
	.clear:focus-visible {
		outline: 2px solid var(--focus-ring);
	}
	.mobile-field {
		display: none;
	}
	.tabs {
		align-self: flex-start;
		max-width: 100%;
	}
	.srch-head,
	.srch-row {
		display: grid;
		grid-template-columns: minmax(0, 1fr) 130px 220px 110px 16px;
		align-items: center;
		gap: 16px;
		padding: 0 20px;
	}
	.srch-head {
		height: 42px;
		border-bottom: 1px solid color-mix(in oklab, var(--color-border) 40%, transparent);
		font-family: var(--font-mono);
		font-size: 11px;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: color-mix(in oklab, var(--color-muted) 80%, var(--color-canvas));
	}
	.srch-rows {
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.srch-rows li + li {
		border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
	}
	.srch-row {
		min-height: 64px;
		color: inherit;
		text-decoration: none;
	}
	.srch-row:hover {
		background: color-mix(in oklab, var(--color-raised) 45%, transparent);
	}
	.srch-row:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: -2px;
	}
	.tile {
		color: var(--color-muted);
	}
	.tile.round {
		border-radius: 999px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
	}
	.who-name.mono {
		font-family: var(--font-mono);
		font-size: 13px;
		letter-spacing: 0.02em;
	}
	.pill {
		display: inline-flex;
		padding: 3px 9px;
		border: 1px solid var(--color-border);
		border-radius: 999px;
		font-size: 12px;
		line-height: 16px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
		white-space: nowrap;
	}
	.m-matched {
		display: none;
	}
	.net {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}
	.net-name {
		font-size: 13px;
		line-height: 16px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
	}
	.net-sub {
		font-size: 12px;
		line-height: 16px;
		color: var(--color-muted);
	}
	.chev {
		display: flex;
		color: var(--color-muted);
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}
	@media (max-width: 1023px) {
		.mobile-field {
			display: block;
		}
		.mobile-field .srch-field {
			margin-top: 0;
			width: 100%;
			background: var(--color-surface);
		}
		.desk-field {
			display: none;
		}
		.tabs {
			align-self: stretch;
		}
		.srch-head {
			display: none;
		}
		.srch-row {
			grid-template-columns: minmax(0, 1fr) auto;
			grid-template-areas:
				'who status'
				'matched status';
			row-gap: 2px;
			padding: 14px 16px;
		}
		.who {
			grid-area: who;
			align-items: flex-start;
		}
		.who .tile {
			width: 36px;
			height: 36px;
		}
		.status {
			grid-area: status;
		}
		.matched {
			grid-area: matched;
			padding-left: 48px;
		}
		.pill,
		.chev {
			display: none;
		}
		.m-matched {
			display: inline;
			font-size: 12px;
			line-height: 16px;
			color: var(--color-muted);
		}
		.net {
			display: none;
		}
	}
</style>
