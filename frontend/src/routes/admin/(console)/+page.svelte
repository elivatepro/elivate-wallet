<!-- Paper "Admin — Screens v1" A03 / A04 · Overview. -->
<script lang="ts">
	import Search from '@lucide/svelte/icons/search';
	import Badge from '#lib/ui/admin/Badge.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import { NETWORK_STATE_LABELS, SWITCH_LABELS } from '#lib/contract/admin.js';
	import {
		NETWORK_TONES,
		RESTORE_LABELS,
		RESTORE_TONES,
		SWITCH_ORDER,
		day,
		initials
	} from '#lib/admin.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	const o = $derived(data.overview);
	const count = (state: string) => o.networks.byState[state] ?? 0;
	const switches = $derived(
		SWITCH_ORDER.map((key) => o.switches.find((s) => s.key === key)).filter((s) => s !== undefined)
	);
	const stopped = $derived(switches.filter((s) => s.stopped).length);
	const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
</script>

<div class="admin-page">
	<RootHero
		pose="member-wallets"
		title={plural(o.networks.total, 'network')}
		lead={`${plural(o.accounts.total, 'account')} · ${count('active')} active · ${count('pending_payment')} waiting for payment`}
	>
		<a class="btn primary hero-cta" href="/admin/search"
			><Search size={16} aria-hidden="true" />Search platform</a
		>
	</RootHero>

	<section class="admin-section" aria-labelledby="switch-strip">
		<div class="admin-section-head">
			<h2 id="switch-strip">Kill switches</h2>
			<p>
				New operations only · existing state is kept{o.networkStops > 0
					? ` · ${plural(o.networkStops, 'stop')} on single networks`
					: ''}
			</p>
			<a class="manage" href="/admin/switches">Manage</a>
		</div>
		<ul class="strip">
			{#each switches as s (s.key)}
				<li class:stopped={s.stopped}>
					<span class="name">{SWITCH_LABELS[s.key].name}</span>
					<span class="state"><span class="dot"></span>{s.stopped ? 'Stopped' : 'Running'}</span>
				</li>
			{/each}
		</ul>
		{#if stopped === 0 && o.networkStops === 0}<p class="sr-only">
				All operations are running.
			</p>{/if}
	</section>

	<div class="two-col">
		<section class="admin-card" aria-labelledby="recent-networks">
			<div class="card-head">
				<h2 id="recent-networks">Networks</h2>
				<a href="/admin/networks">View all</a>
			</div>
			{#if o.recentNetworks.length === 0}
				<p class="admin-empty">No networks yet.</p>
			{:else}
				<table class="admin-table collapse">
					<thead><tr><th>Network</th><th>Status</th><th class="num">Seats</th></tr></thead>
					<tbody>
						{#each o.recentNetworks as n (n.tenantId)}
							<tr>
								<td>
									<a class="who row-link" href={`/admin/networks/${n.tenantId}`}>
										<span class="tile">{initials(n.name)}</span>
										<span class="who-text">
											<span class="who-name">{n.name}</span>
											<span class="who-sub">
												{n.state === 'pending_payment'
													? `Founder ${n.founder?.name ?? n.founder?.uid ?? ''}`
													: `${plural(n.officeCount, 'office')}${n.presidents[0] ? ` · President ${n.presidents[0].name ?? n.presidents[0].uid}` : ''}`}
											</span>
										</span>
									</a>
								</td>
								<td data-label="Status"
									><Badge tone={NETWORK_TONES[n.state]}>{NETWORK_STATE_LABELS[n.state]}</Badge></td
								>
								<td class="num" data-label="Seats">
									{n.state === 'pending_payment' ? '—' : `${n.seats.used} / ${n.seats.cap ?? '∞'}`}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			{/if}
		</section>

		<div class="stack">
			<section class="admin-card" aria-labelledby="open-restores">
				<div class="card-head">
					<h2 id="open-restores">Open restore requests</h2>
					{#if o.openRestores.length > 0}<Badge tone="accent">{o.openRestores.length}</Badge>{/if}
				</div>
				{#if o.openRestores.length === 0}
					<p class="admin-empty">None open.</p>
				{:else}
					<ul class="list">
						{#each o.openRestores as r (r.restoreId)}
							<li>
								<a href={`/admin/backups/${r.restoreId}`}>
									<span class="who-text">
										<span class="who-name">{r.network}</span>
										<span class="who-sub mono">{r.reference} · Requested {day(r.createdAt)}</span>
									</span>
									<Badge tone={RESTORE_TONES[r.status as keyof typeof RESTORE_TONES] ?? 'neutral'}>
										{RESTORE_LABELS[r.status as keyof typeof RESTORE_LABELS] ?? r.status}
									</Badge>
								</a>
							</li>
						{/each}
					</ul>
				{/if}
			</section>
			<section class="admin-card" aria-labelledby="attention">
				<div class="card-head"><h2 id="attention">Needs attention</h2></div>
				<ul class="list">
					<li>
						<a href="/admin/applications">
							<span class="who-name">Founder applications</span>
							<Badge tone={o.founderApplications > 0 ? 'warning' : 'neutral'}
								>{o.founderApplications}</Badge
							>
						</a>
					</li>
					<li>
						<a href="/admin/emails">
							<span class="who-name">Failed emails</span>
							<Badge tone={o.failedEmails > 0 ? 'danger' : 'neutral'}>{o.failedEmails}</Badge>
						</a>
					</li>
					<li>
						<a href="/admin/nin">
							<span class="who-name">NIN reviews</span>
							<Badge tone={o.ninReviews > 0 ? 'warning' : 'neutral'}>{o.ninReviews}</Badge>
						</a>
					</li>
					<li>
						<a href="/admin/audit">
							<span class="who-name">Platform audit</span>
							<span class="who-sub">Open</span>
						</a>
					</li>
				</ul>
			</section>
		</div>
	</div>
</div>

<style>
	.hero-cta {
		align-self: flex-start;
		margin-top: 20px;
		min-height: 46px;
		padding: 0 20px;
		position: relative;
	}
	.manage {
		font-size: 13px;
		font-weight: 500;
		color: var(--color-accent-text);
		text-decoration: none;
	}
	.strip {
		display: grid;
		grid-template-columns: repeat(4, minmax(0, 1fr));
		gap: 12px;
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.strip li {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 16px;
		border-radius: 14px;
		background: var(--color-surface);
		border: 1px solid color-mix(in oklab, var(--color-border) 70%, transparent);
	}
	.strip li.stopped {
		background: color-mix(in oklab, var(--color-danger) 8%, var(--color-surface));
		border-color: color-mix(in oklab, var(--color-danger) 35%, transparent);
	}
	.name {
		font-size: 13px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
	}
	.state {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		font-size: 15px;
		font-weight: 500;
		color: var(--color-success);
	}
	.stopped .state {
		color: var(--color-danger);
	}
	.dot {
		width: 7px;
		height: 7px;
		border-radius: 999px;
		background: currentColor;
	}
	.card-head {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 18px 20px 14px;
	}
	.card-head h2 {
		flex: 1 1 auto;
	}
	.card-head a {
		font-size: 13px;
		font-weight: 500;
		color: var(--color-accent-text);
		text-decoration: none;
	}
	.list {
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.list a {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		min-height: 60px;
		padding: 10px 20px;
		border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
		color: inherit;
		text-decoration: none;
	}
	.list a:hover {
		background: color-mix(in oklab, var(--color-raised) 45%, transparent);
	}
	.mono {
		font-family: var(--font-mono);
		font-size: 11px;
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}
	@media (max-width: 1023px) {
		.strip {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
	}
</style>
