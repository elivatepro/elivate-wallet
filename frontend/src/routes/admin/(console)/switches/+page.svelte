<!-- Paper "Admin — Screens v1" A11v2d / A11v2m · Kill switches; A11b stop and A11cd / A11cm start dialogs. -->
<script lang="ts">
	import { page } from '$app/state';
	import ArrowRight from '@lucide/svelte/icons/arrow-right';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import AdminDialog from '#lib/ui/admin/AdminDialog.svelte';
	import Badge from '#lib/ui/admin/Badge.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import { SWITCH_LABELS, type SwitchKey } from '#lib/contract/admin.js';
	import { SWITCH_ORDER, initials, when } from '#lib/admin.js';
	import { plural, shortName } from '#lib/ui/admin/MiscText.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();

	/** What pauses or opens again, for the dialog lead. */
	const NOUNS: Readonly<Record<SwitchKey, string>> = {
		withdrawals: 'requests',
		transfers: 'transfers',
		payouts: 'payout records',
		conversion: 'conversions',
		income: 'income records',
		adjustments: 'adjustments',
		reversals: 'reversals',
		returned_funds: 'returned funds records'
	};

	const rows = $derived(
		SWITCH_ORDER.map((key) => data.switches.platform.find((s) => s.key === key)).filter(
			(s) => s !== undefined
		)
	);
	const stoppedCount = $derived(rows.filter((s) => s.stopped).length);
	const networkStops = $derived(data.switches.networks.filter((s) => s.stopped));
	const changed = (s: {
		changedBy: { name: string | null; uid: string } | null;
		changedAt: string | null;
	}) =>
		s.changedAt
			? `${shortName(s.changedBy?.name ?? s.changedBy?.uid)} · ${when(s.changedAt)}`
			: null;

	const dialog = $derived(page.url.searchParams.get('dialog'));
	const dialogKey = $derived(page.url.searchParams.get('key'));
	const target = $derived(
		dialog === 'stop' || dialog === 'start'
			? rows.find((s) => s.key === dialogKey && s.stopped === (dialog === 'start'))
			: undefined
	);
</script>

<div class="admin-page">
	<RootHero
		pose="admin-switches"
		title={stoppedCount === 0
			? 'All switches running'
			: `${plural(stoppedCount, 'platform switch', 'platform switches')} stopped`}
		lead="Switches stop new operations. Existing state and history stay intact."
	/>

	<section class="admin-section" aria-labelledby="sw-title">
		<div class="admin-section-head">
			<h2 id="sw-title">Kill switches</h2>
			<p>Each switch is independent · reason and PIN to change</p>
		</div>
		<div class="admin-card">
			<div class="sw-head" aria-hidden="true">
				<span>Operation</span><span>State</span><span>Last changed</span><span></span>
			</div>
			<ul class="sw-rows">
				{#each rows as s (s.key)}
					{@const label = SWITCH_LABELS[s.key]}
					{@const last = changed(s)}
					<li class="sw-row">
						<span class="op">
							<span class="op-name">{label.name}</span>
							<span class="op-detail">{label.detail}</span>
							<span class="m-state" class:stopped={s.stopped}
								>{s.stopped ? 'Stopped' : 'Running'} · {last ?? 'never changed'}</span
							>
						</span>
						<span class="state"
							><Badge tone={s.stopped ? 'danger' : 'success'}
								>{s.stopped ? 'Stopped' : 'Running'}</Badge
							></span
						>
						<span class="last">{last ?? 'Never changed'}</span>
						<a
							class="sw-toggle"
							class:on={!s.stopped}
							href={`?dialog=${s.stopped ? 'start' : 'stop'}&key=${s.key}`}
							role="switch"
							aria-checked={!s.stopped}
							aria-label={`${label.name}: ${s.stopped ? 'stopped, start again' : 'running, stop'}`}
							><span class="knob"></span></a
						>
					</li>
				{/each}
				<li class="sw-row deferred">
					<span class="op">
						<span class="op-name">Automated payouts</span>
						<span class="op-detail">Not part of this release</span>
						<span class="m-state">Deferred</span>
					</span>
					<span class="state"><span class="dashed-pill">Deferred</span></span>
					<span class="last">—</span>
					<span class="sw-toggle dashed" aria-hidden="true"></span>
				</li>
			</ul>
		</div>
	</section>

	{#if networkStops.length > 0}
		<section class="admin-section" aria-labelledby="sw-networks">
			<div class="admin-section-head">
				<h2 id="sw-networks">Stopped on one network</h2>
				<p>Change these on the network’s page</p>
			</div>
			<ul class="admin-card sw-net-list">
				{#each networkStops as s (`${s.tenantId}-${s.key}`)}
					{@const last = changed(s)}
					<li>
						<a class="sw-net" href={`/admin/networks/${s.tenantId}`}>
							<span class="tile">{initials(s.network, 'N')}</span>
							<span class="who-text">
								<span class="who-name"
									><span class="n-name">{s.network ?? 'Network'}</span><span class="n-sep">
										·
									</span><span class="n-key">{SWITCH_LABELS[s.key].name}</span></span
								>
								<span class="who-sub">{[last, s.reason].filter(Boolean).join(' · ')}</span>
							</span>
							<Badge tone="danger">Stopped</Badge>
							<span class="chev" aria-hidden="true"><ChevronRight size={16} /></span>
						</a>
					</li>
				{/each}
			</ul>
		</section>
	{/if}
</div>

{#if target}
	{@const label = SWITCH_LABELS[target.key]}
	{@const stopping = !target.stopped}
	<AdminDialog
		pose="admin-switches"
		title={stopping
			? `Stop ${label.name.toLowerCase()}?`
			: `Start ${label.name.toLowerCase()} again?`}
		lead={stopping
			? `New ${NOUNS[target.key]} pause on every network. Open ones keep their state.`
			: `New ${NOUNS[target.key]} open on every network.`}
		action={`?dialog=${stopping ? 'stop' : 'start'}&key=${target.key}&/${stopping ? 'stop' : 'start'}`}
		cancelHref="/admin/switches"
		submitLabel={`${stopping ? 'Stop' : 'Start'} ${label.name.toLowerCase()}`}
		tone={stopping ? 'danger' : 'primary'}
		idempotencyKey={data.idempotencyKey}
		error={form?.error ?? null}
		reason={form?.reason ?? ''}
	>
		<input type="hidden" name="key" value={target.key} />
		<div class="sw-transition">
			<span class="t-name">{label.name}</span>
			<span class="chip {stopping ? 'run' : 'stop'}">{stopping ? 'Running' : 'Stopped'}</span>
			<ArrowRight size={18} aria-label="to" />
			<span class="chip {stopping ? 'stop' : 'run'}">{stopping ? 'Stopped' : 'Running'}</span>
		</div>
	</AdminDialog>
{/if}

<style>
	.sw-head,
	.sw-row {
		display: grid;
		grid-template-columns: minmax(0, 1fr) 120px 200px 44px;
		align-items: center;
		gap: 16px;
		padding: 0 20px;
	}
	.sw-head {
		height: 42px;
		border-bottom: 1px solid color-mix(in oklab, var(--color-border) 40%, transparent);
		font-family: var(--font-mono);
		font-size: 11px;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: color-mix(in oklab, var(--color-muted) 80%, var(--color-canvas));
	}
	.sw-rows {
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.sw-row {
		min-height: 64px;
	}
	.sw-row + .sw-row {
		border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
	}
	.op {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}
	.op-name {
		font-size: 14px;
		font-weight: 500;
		line-height: 18px;
		color: var(--color-text);
	}
	.op-detail {
		font-size: 12px;
		line-height: 16px;
		color: var(--color-muted);
	}
	.m-state {
		display: none;
	}
	.last {
		font-size: 13px;
		line-height: 16px;
		color: var(--color-muted);
	}
	.deferred .op-name {
		color: var(--color-muted);
	}
	.dashed-pill {
		display: inline-flex;
		padding: 3px 9px;
		border: 1px dashed var(--color-border);
		border-radius: 999px;
		font-size: 12px;
		font-weight: 500;
		line-height: 16px;
		color: var(--color-muted);
	}
	.sw-toggle {
		display: flex;
		align-items: center;
		width: 44px;
		height: 26px;
		padding: 3px;
		border: 1px solid color-mix(in oklab, var(--color-danger) 30%, transparent);
		border-radius: 999px;
		background: color-mix(in oklab, var(--color-danger) 16%, var(--color-surface));
		box-sizing: border-box;
	}
	.sw-toggle .knob {
		width: 18px;
		height: 18px;
		border-radius: 999px;
		background: var(--color-danger);
	}
	.sw-toggle.on {
		justify-content: flex-end;
		border-color: transparent;
		background: var(--color-success);
	}
	.sw-toggle.on .knob {
		width: 20px;
		height: 20px;
		background: #f2f4f4;
	}
	.sw-toggle.dashed {
		border: 1px dashed var(--color-border);
		background: transparent;
	}
	.sw-toggle:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 2px;
	}
	.sw-net-list {
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.sw-net-list li + li {
		border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
	}
	.sw-net {
		display: flex;
		align-items: center;
		gap: 16px;
		min-height: 60px;
		padding: 10px 20px;
		color: inherit;
		text-decoration: none;
	}
	.sw-net:hover {
		background: color-mix(in oklab, var(--color-raised) 45%, transparent);
	}
	.sw-net:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: -2px;
	}
	.sw-net .who-text {
		flex: 1 1 auto;
	}
	.chev {
		display: flex;
		color: var(--color-muted);
	}
	.sw-transition {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 14px 16px;
		background: var(--color-canvas);
		border: 1px solid var(--color-border);
		border-radius: 14px;
		color: var(--color-muted);
	}
	.t-name {
		flex: 1 1 auto;
		font-size: 14px;
		line-height: 18px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
	}
	.chip {
		padding: 3px 10px;
		border-radius: 999px;
		font-size: 13px;
		font-weight: 500;
		line-height: 16px;
		white-space: nowrap;
	}
	.chip.run {
		background: color-mix(in oklab, var(--color-success) 16%, var(--color-surface));
		color: var(--color-success);
	}
	.chip.stop {
		background: color-mix(in oklab, var(--color-danger) 16%, var(--color-surface));
		color: var(--color-danger);
	}
	@media (max-width: 1023px) {
		.sw-head {
			display: none;
		}
		.sw-row {
			grid-template-columns: minmax(0, 1fr) 44px;
			padding: 14px 16px;
		}
		.state,
		.last {
			display: none;
		}
		.m-state {
			display: block;
			margin-top: 2px;
			font-size: 12px;
			line-height: 16px;
			color: var(--color-success);
		}
		.m-state.stopped {
			color: var(--color-danger);
		}
		.deferred .m-state {
			color: var(--color-muted);
		}
		.sw-net {
			display: grid;
			grid-template-columns: 36px minmax(0, 1fr) auto 16px;
			align-items: start;
			padding: 14px 16px;
		}
		.sw-net .tile {
			width: 36px;
			height: 36px;
			margin-top: 6px;
		}
		.n-key {
			display: block;
			font-weight: 400;
		}
		.n-sep {
			display: none;
		}
		.chev {
			align-self: center;
		}
		.sw-transition {
			padding: 12px 14px;
		}
	}
</style>
