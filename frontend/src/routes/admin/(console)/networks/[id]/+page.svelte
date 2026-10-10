<!--
	Approved draft A07v2d / A07v2m · Network detail: hero with Network audit and
	Support activation (A07bd/A07bm dialog), subscription, organisation,
	white-label (not active, U-05), kill switches for this network (stop/start
	dialog, A11b pattern) and pockets & split (read only; Presidents edit them).
-->
<script lang="ts">
	import { page } from '$app/state';
	import Shield from '@lucide/svelte/icons/shield';
	import AdminDialog from '#lib/ui/admin/AdminDialog.svelte';
	import NetHero from '#lib/ui/admin/NetHero.svelte';
	import { NETWORK_STATE_LABELS, SWITCH_LABELS, type SwitchKey } from '#lib/contract/admin.js';
	import { NETWORK_TONES, SWITCH_ORDER, day, withQuery } from '#lib/admin.js';
	import {
		monthOf,
		percentLabel,
		planDetail,
		plural,
		seatPercent,
		shortName,
		sortedVersions,
		switchTiles,
		versionSource
	} from '#lib/admin-networks.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	type FormState = { error?: string; reason?: string; key?: string; mode?: string; until?: string };
	const fv = $derived(form as FormState | null | undefined);
	const n = $derived(data.network);
	const owner = $derived(n.subscription?.owner as { uid: string; name: string | null } | null);
	const president = $derived(n.presidents[0] ?? null);
	const tiles = $derived(
		switchTiles(SWITCH_ORDER, data.switches.platform, data.switches.networks, n.tenantId)
	);
	const versions = $derived(sortedVersions(data.versions));
	const current = $derived(versions[0] ?? null);
	const showAll = $derived(page.url.searchParams.get('versions') === 'all');

	const dialog = $derived(page.url.searchParams.get('dialog'));
	const dialogKey = $derived(page.url.searchParams.get('key') as SwitchKey | null);
	const closeHref = $derived(withQuery(page.url, { dialog: null, key: null }));
	const switchTile = $derived(tiles.find((t) => t.key === dialogKey) ?? null);
	const byType = (type: string) => n.organization.byType[type] ?? 0;
	const orgLine = $derived(
		[
			byType('world_team') ? plural(byType('world_team'), 'World Team', 'World Teams') : null,
			byType('director') ? plural(byType('director'), 'directorate') : null,
			byType('team_leader') ? plural(byType('team_leader'), 'team office') : null
		]
			.filter(Boolean)
			.join(' · ')
	);
</script>

<div class="admin-page">
	<NetHero
		pose="admin-network"
		title={n.name}
		status={NETWORK_STATE_LABELS[n.state]}
		tone={NETWORK_TONES[n.state]}
	>
		{#snippet line()}
			{president
				? `President ${shortName(president.name) || president.uid}`
				: `Founder ${shortName(n.founder?.name) || n.founder?.uid || ''}`} · Network since {monthOf(
				n.createdAt
			)}
		{/snippet}
		{#snippet actions()}
			<a class="btn" href={`/admin/audit?tenantId=${n.tenantId}`}>Network audit</a>
			<a class="btn" href={withQuery(page.url, { dialog: 'activate', key: null })}>
				<Shield size={14} aria-hidden="true" />Support activation
			</a>
		{/snippet}
	</NetHero>

	<div class="two-col">
		<section class="admin-card padded" aria-labelledby="sub-head">
			<div class="row-head">
				<h2 id="sub-head">Subscription</h2>
			</div>
			{#if n.state === 'pending_payment'}
				<p class="muted">No plan yet. The founder hasn’t paid.</p>
			{:else}
				<div class="seats">
					<p>
						<strong>{n.seats.used}</strong>
						<span
							>{n.seats.cap
								? `of ${n.seats.cap.toLocaleString('en-NG')} seats used`
								: 'seats used'}</span
						>
					</p>
					<span class="muted">{plural(n.organization.memberships, 'membership')}</span>
				</div>
				{#if n.seats.cap}
					<div class="bar" aria-hidden="true">
						<span style={`width:${seatPercent(n.seats)}%`}></span>
					</div>
				{/if}
				<dl class="kv">
					<div>
						<dt>Plan</dt>
						<dd>{planDetail(n)}</dd>
					</div>
					<div>
						<dt>Current period</dt>
						<dd>
							{n.subscription?.periodStart ? day(n.subscription.periodStart) : '—'} – {n
								.subscription?.periodEnd
								? day(n.subscription.periodEnd)
								: 'no end date'}
						</dd>
					</div>
					<div>
						<dt>Billing Owner</dt>
						<dd>{owner ? (owner.name ?? owner.uid) : '—'}</dd>
					</div>
					<div>
						<dt>Extras</dt>
						<dd class="muted">None activated</dd>
					</div>
				</dl>
			{/if}
		</section>

		<div class="stack">
			<section class="admin-card padded" aria-labelledby="org-head">
				<h2 id="org-head">Organization</h2>
				<div class="stats">
					<div><strong>{n.organization.offices}</strong><span>Offices</span></div>
					<div><strong>{n.organization.memberships}</strong><span>Memberships</span></div>
					<div><strong>{n.organization.people}</strong><span>People</span></div>
				</div>
				{#if orgLine}<p class="muted small">{orgLine}</p>{/if}
			</section>
			<section class="admin-card padded dashed" aria-labelledby="wl-head">
				<div class="row-head">
					<h2 id="wl-head">White-label domain</h2>
					<span class="pill">Not active</span>
				</div>
				<p class="muted small">Domain activation isn’t available yet.</p>
			</section>
		</div>
	</div>

	<section class="admin-card padded" aria-labelledby="sw-head">
		<div class="row-head">
			<h2 id="sw-head">Kill switches for this network</h2>
			<span class="muted small">Platform switches apply too</span>
		</div>
		<ul class="tiles">
			{#each tiles as t (t.key)}
				{@const stopped = t.platformStopped || t.networkStopped}
				<li class:stopped={t.networkStopped}>
					<span class="tile-text">
						<span class="tile-name">{SWITCH_LABELS[t.key].name}</span>
						<span class="tile-state" class:off={stopped}>
							<span class="dot"></span>{t.platformStopped
								? 'Stopped · all networks'
								: t.networkStopped
									? 'Stopped here'
									: 'Running'}
						</span>
					</span>
					{#if t.platformStopped}
						<span class="toggle disabled" aria-hidden="true"><span></span></span>
					{:else}
						<a
							class="toggle"
							class:off={t.networkStopped}
							href={withQuery(page.url, { dialog: 'switch', key: t.key })}
							aria-label={`${t.networkStopped ? 'Start' : 'Stop'} ${SWITCH_LABELS[t.key].name.toLowerCase()} on ${n.name}`}
							><span></span></a
						>
					{/if}
				</li>
			{/each}
		</ul>
	</section>

	<section class="admin-card padded" aria-labelledby="split-head">
		<div class="row-head">
			<h2 id="split-head">Pockets &amp; split</h2>
			<span class="muted small grow">
				{current
					? `Version ${current.version} · since ${day(current.createdAt)} · ${versionSource(current.source)}`
					: 'No split yet'}
			</span>
			{#if versions.length > 1}
				<a class="link" href={withQuery(page.url, { versions: showAll ? null : 'all' })}>
					{showAll ? 'Current only' : `All ${versions.length} versions`}
				</a>
			{/if}
		</div>
		{#if current}
			<ul class="pockets">
				{#each current.pockets as p (p.pocketId)}
					<li><strong>{percentLabel(p.percent)}</strong><span>{p.name}</span></li>
				{/each}
				<li class="debt"><strong>—</strong><span>Debt · fixed</span></li>
			</ul>
		{/if}
		{#if showAll}
			<ol class="versions">
				{#each versions as v (v.policyId)}
					<li>
						<span class="mono">v{v.version} · {day(v.createdAt)}</span>
						<span>{v.pockets.map((p) => `${p.name} ${percentLabel(p.percent)}`).join(' · ')}</span>
						{#if v.reason}<span class="muted">{v.reason}</span>{/if}
					</li>
				{/each}
			</ol>
		{/if}
	</section>
</div>

{#if dialog === 'activate'}
	<AdminDialog
		pose="payment-confirmed"
		title="Support activation"
		lead={`${n.name} · never counted as a payment`}
		action="?/activate"
		cancelHref={closeHref}
		submitLabel="Activate"
		idempotencyKey={fv?.key ?? data.activateKey}
		error={fv?.error ?? null}
		reason={fv?.reason ?? ''}
	>
		<fieldset class="choice">
			<legend class="sr-only">How to activate</legend>
			<label class="option">
				<input
					type="radio"
					name="mode"
					value="complimentary"
					checked={fv?.mode !== 'development'}
				/>
				<span class="option-text">Complimentary until</span>
				<input
					type="date"
					name="until"
					min={data.today}
					value={fv?.until ?? ''}
					aria-label="Last free day"
				/>
			</label>
			<label class="option">
				<input type="radio" name="mode" value="development" checked={fv?.mode === 'development'} />
				<span class="option-text">Development exception · no end date</span>
			</label>
		</fieldset>
	</AdminDialog>
{:else if dialog === 'switch' && switchTile && !switchTile.platformStopped}
	{@const stopping = !switchTile.networkStopped}
	{@const label = SWITCH_LABELS[switchTile.key].name}
	<AdminDialog
		pose="admin-switches"
		title={stopping
			? `Stop ${label.toLowerCase()} on ${n.name}?`
			: `Start ${label.toLowerCase()} again?`}
		lead={stopping
			? 'New operations pause on this network. Open ones keep their state.'
			: `New operations open on ${n.name}.`}
		action="?/switch"
		cancelHref={closeHref}
		submitLabel={stopping ? `Stop ${label.toLowerCase()}` : `Start ${label.toLowerCase()}`}
		tone={stopping ? 'danger' : 'primary'}
		idempotencyKey={fv?.key ?? data.switchKey}
		error={fv?.error ?? null}
		reason={fv?.reason ?? ''}
	>
		<input type="hidden" name="key" value={switchTile.key} />
		<input type="hidden" name="stopped" value={String(stopping)} />
		<div class="transition">
			<span>{label}</span>
			<span class="chips">
				<span class="chip" class:run={stopping} class:stop={!stopping}
					>{stopping ? 'Running' : 'Stopped'}</span
				>
				→
				<span class="chip" class:run={!stopping} class:stop={stopping}
					>{stopping ? 'Stopped' : 'Running'}</span
				>
			</span>
		</div>
	</AdminDialog>
{/if}

<style>
	.row-head {
		display: flex;
		align-items: center;
		gap: 12px;
		flex-wrap: wrap;
	}
	.row-head h2 {
		flex: 0 1 auto;
	}
	.grow {
		flex: 1 1 auto;
	}
	.muted {
		color: var(--color-muted);
	}
	.small {
		margin: 0;
		font-size: 13px;
		line-height: 18px;
	}
	.link {
		font-size: 13px;
		font-weight: 500;
		color: var(--color-accent-text);
		text-decoration: none;
	}
	.seats {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 12px;
	}
	.seats p {
		display: flex;
		align-items: baseline;
		gap: 8px;
		margin: 0;
	}
	.seats strong {
		font-size: 32px;
		font-weight: 500;
		line-height: 36px;
	}
	.seats span {
		font-size: 14px;
	}
	.bar {
		height: 8px;
		border-radius: 999px;
		background: var(--color-raised);
		overflow: hidden;
	}
	.bar span {
		display: block;
		height: 100%;
		border-radius: 999px;
		background: var(--color-accent);
	}
	.dashed {
		border-style: dashed;
		background: transparent;
	}
	.pill {
		margin-left: auto;
		padding: 3px 9px;
		border-radius: 999px;
		background: var(--color-raised);
		font-size: 12px;
		color: var(--color-muted);
	}
	.tiles {
		display: grid;
		grid-template-columns: repeat(4, minmax(0, 1fr));
		gap: 10px;
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.tiles li {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 14px 16px;
		border-radius: 12px;
		background: color-mix(in oklab, var(--color-raised) 55%, var(--color-surface));
		border: 1px solid color-mix(in oklab, var(--color-border) 70%, transparent);
	}
	.tiles li.stopped {
		background: color-mix(in oklab, var(--color-danger) 8%, var(--color-surface));
		border-color: color-mix(in oklab, var(--color-danger) 35%, transparent);
	}
	.tile-text {
		display: flex;
		flex: 1 1 auto;
		flex-direction: column;
		gap: 4px;
		min-width: 0;
	}
	.tile-name {
		font-size: 14px;
		font-weight: 500;
	}
	.tile-state {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		font-size: 13px;
		color: var(--color-success);
	}
	.tile-state.off {
		color: var(--color-danger);
	}
	.dot {
		width: 7px;
		height: 7px;
		border-radius: 999px;
		background: currentColor;
	}
	.toggle {
		display: flex;
		flex-shrink: 0;
		justify-content: flex-end;
		width: 40px;
		height: 24px;
		padding: 3px;
		border-radius: 999px;
		background: color-mix(in oklab, var(--color-success) 55%, var(--color-surface));
	}
	.toggle span {
		width: 18px;
		height: 18px;
		border-radius: 999px;
		background: #f2f4f4;
	}
	.toggle.off {
		justify-content: flex-start;
		background: color-mix(in oklab, var(--color-danger) 25%, var(--color-surface));
	}
	.toggle.off span {
		background: var(--color-danger);
	}
	.toggle.disabled {
		justify-content: flex-start;
		background: var(--color-raised);
		opacity: 0.6;
	}
	.toggle.disabled span {
		background: var(--color-muted);
	}
	.toggle:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 2px;
	}
	.pockets {
		display: grid;
		grid-template-columns: repeat(6, minmax(0, 1fr));
		gap: 10px;
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.pockets li {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 14px 16px;
		border-radius: 12px;
		background: color-mix(in oklab, var(--color-raised) 55%, var(--color-surface));
	}
	.pockets strong {
		font-size: 22px;
		font-weight: 600;
		line-height: 28px;
	}
	.pockets span {
		font-size: 13px;
		color: var(--color-muted);
	}
	.pockets .debt {
		background: transparent;
		border: 1px dashed var(--color-border);
	}
	.pockets .debt strong {
		color: var(--color-muted);
	}
	.versions {
		display: flex;
		flex-direction: column;
		gap: 10px;
		margin: 0;
		padding: 0;
		list-style: none;
		font-size: 13px;
	}
	.versions li {
		display: flex;
		flex-direction: column;
		gap: 2px;
		padding-top: 10px;
		border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
	}
	.mono {
		font-family: var(--font-mono);
		font-size: 12px;
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
		min-height: 56px;
		padding: 10px 16px;
		border-radius: 12px;
		border: 1px solid var(--color-border);
		font-size: 14px;
	}
	.option:has(input[type='radio']:checked) {
		background: var(--color-raised);
	}
	.option-text {
		flex: 1 1 auto;
	}
	.option input[type='radio'] {
		accent-color: var(--color-accent);
	}
	.option input[type='date'] {
		height: 36px;
		padding: 0 10px;
		border-radius: 9px;
		border: 1px solid var(--color-border);
		background: var(--color-canvas);
		font: inherit;
		color: var(--color-text);
		color-scheme: dark;
	}
	.transition {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 14px 16px;
		border-radius: 12px;
		border: 1px solid var(--color-border);
		font-size: 14px;
	}
	.chips {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		color: var(--color-muted);
	}
	.chip {
		padding: 3px 10px;
		border-radius: 999px;
		font-size: 13px;
		font-weight: 500;
	}
	.chip.run {
		background: color-mix(in oklab, var(--color-success) 16%, var(--color-surface));
		color: var(--color-success);
	}
	.chip.stop {
		background: color-mix(in oklab, var(--color-danger) 16%, var(--color-surface));
		color: var(--color-danger);
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}
	@media (max-width: 1023px) {
		.tiles {
			grid-template-columns: minmax(0, 1fr);
		}
		.pockets {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
	}
</style>
