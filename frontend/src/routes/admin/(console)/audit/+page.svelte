<!-- Paper "Admin — Screens v1" A13 / A14 · Platform audit (read-only; rows open without JavaScript). -->
<script lang="ts">
	import { page } from '$app/state';
	import SearchIcon from '@lucide/svelte/icons/search';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import X from '@lucide/svelte/icons/x';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import {
		AUDIT_GROUPS,
		SWITCH_LABELS,
		type AuditEvent,
		type SwitchKey
	} from '#lib/contract/admin.js';
	import { actionLabel, initials, withQuery } from '#lib/admin.js';
	import { shortName } from '#lib/ui/admin/MiscText.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	const f = $derived(data.filters);

	const GROUP_LABELS: Readonly<Record<(typeof AUDIT_GROUPS)[number], string>> = {
		controls: 'Controls',
		accounts: 'Accounts',
		money: 'Money',
		backups: 'Backups',
		network: 'Network'
	};

	const WAT = 'Africa/Lagos';
	const dayKey = new Intl.DateTimeFormat('en-CA', {
		year: 'numeric',
		month: '2-digit',
		day: '2-digit',
		timeZone: WAT
	});
	const hm = new Intl.DateTimeFormat('en-GB', {
		hour: '2-digit',
		minute: '2-digit',
		hour12: false,
		timeZone: WAT
	});
	const weekday = new Intl.DateTimeFormat('en-GB', { weekday: 'short', timeZone: WAT });
	const dayMonth = new Intl.DateTimeFormat('en-GB', {
		day: 'numeric',
		month: 'short',
		timeZone: WAT
	});
	const fullDay = new Intl.DateTimeFormat('en-GB', {
		day: 'numeric',
		month: 'short',
		year: 'numeric',
		timeZone: WAT
	});

	/** "TODAY 09:14", "YESTERDAY 18:20", "TUE 16:20", "3 OCT 09:14", "3 OCT 2025". */
	function stamp(iso: string, now = new Date()): string {
		const at = new Date(iso);
		const days = Math.round(
			(Date.parse(dayKey.format(now)) - Date.parse(dayKey.format(at))) / 86_400_000
		);
		const time = hm.format(at);
		const label =
			days === 0
				? `Today ${time}`
				: days === 1
					? `Yesterday ${time}`
					: days > 1 && days < 7
						? `${weekday.format(at)} ${time}`
						: at.getFullYear() === now.getFullYear()
							? `${dayMonth.format(at)} ${time}`
							: fullDay.format(at);
		return label.toUpperCase();
	}

	const isRecord = (v: unknown): v is Record<string, unknown> =>
		typeof v === 'object' && v !== null && !Array.isArray(v);

	/** Top-level "key: value" lines; nested values as indented JSON. */
	function lines(value: unknown): string {
		if (value === null || value === undefined) return '—';
		if (!isRecord(value)) return JSON.stringify(value, null, 2);
		const entries = Object.entries(value);
		if (entries.length === 0) return '—';
		return entries
			.map(
				([k, v]) =>
					`${k}: ${typeof v === 'object' && v !== null ? JSON.stringify(v, null, 2) : String(v)}`
			)
			.join('\n');
	}

	function target(e: AuditEvent): string {
		if (e.target) return `${e.target.name ?? e.target.uid} · ${e.target.uid}`;
		const after = isRecord(e.after) ? e.after : {};
		const before = isRecord(e.before) ? e.before : {};
		const reference = after.reference ?? before.reference;
		if (typeof reference === 'string') return e.network ? `${reference} · ${e.network}` : reference;
		const key = after.key ?? before.key;
		if (typeof key === 'string' && key in SWITCH_LABELS) {
			const name = SWITCH_LABELS[key as SwitchKey].name;
			return e.network ? `${name} · ${e.network}` : name;
		}
		return e.network ?? e.targetId ?? '—';
	}

	const actorKind = (e: AuditEvent) =>
		!e.actor ? 'Automated' : e.actorIsAdmin ? 'Platform' : 'Network';
	const filtering = $derived(Boolean(f.q || f.actor || f.group || f.from || f.to));
	const clearTenant = $derived(withQuery(page.url, { tenantId: null, cursor: null }));
</script>

<div class="admin-page">
	<RootHero
		pose="admin-audit"
		title={`${data.items.length}${data.nextCursor ? '+' : ''} ${data.items.length === 1 && !data.nextCursor ? 'event' : 'events'}`}
		lead="Read-only. Entries can’t be edited or deleted."
	/>

	<form class="aud-filters" method="GET" action="/admin/audit" aria-label="Filter the audit">
		<label class="aud-box search">
			<SearchIcon size={16} aria-hidden="true" />
			<span class="sr-only">Search</span>
			<input
				name="q"
				type="search"
				value={f.q ?? ''}
				maxlength="100"
				placeholder="Search action, target or reference"
			/>
		</label>
		<label class="aud-box">
			<span class="k">Actor</span>
			<input
				class="uid"
				name="actor"
				value={f.actorRaw}
				placeholder="EW-…"
				autocomplete="off"
				spellcheck="false"
				maxlength="20"
			/>
		</label>
		<label class="aud-box">
			<span class="k">Action</span>
			<select name="group">
				<option value="" selected={!f.group}>All</option>
				{#each AUDIT_GROUPS as g (g)}
					<option value={g} selected={f.group === g}>{GROUP_LABELS[g]}</option>
				{/each}
			</select>
			<ChevronDown size={14} aria-hidden="true" />
		</label>
		{#if f.tenantId}
			<input type="hidden" name="tenantId" value={f.tenantId} />
			<span class="aud-box chip">
				<span class="k">Network</span><span class="v">{data.networkName ?? '—'}</span>
				<a href={clearTenant} aria-label="Show every network"><X size={14} /></a>
			</span>
		{/if}
		<label class="aud-box">
			<span class="k">From</span>
			<input name="from" type="date" value={f.from ?? ''} />
		</label>
		<label class="aud-box">
			<span class="k">To</span>
			<input name="to" type="date" value={f.to ?? ''} />
		</label>
		<button class="btn small" type="submit">Apply</button>
		{#if filtering}
			<a class="reset" href={f.tenantId ? `/admin/audit?tenantId=${f.tenantId}` : '/admin/audit'}
				>Clear</a
			>
		{/if}
	</form>

	<section class="admin-card" aria-label="Audit events">
		{#if data.items.length === 0}
			<p class="admin-empty">{filtering || f.tenantId ? 'No events match.' : 'No events yet.'}</p>
		{:else}
			<div class="aud-head" aria-hidden="true">
				<span>Time</span><span>Actor</span><span>Action</span><span>Target</span><span>Reason</span
				><span></span>
			</div>
			<ul class="aud-rows">
				{#each data.items as e (e.eventId)}
					{@const who = e.actor ? shortName(e.actor.name ?? e.actor.uid) : 'System'}
					{@const tgt = target(e)}
					<li>
						<details>
							<summary>
								<span class="time">{stamp(e.at)}</span>
								<span class="actor">
									<span class="mini">{e.actor ? initials(e.actor.name, 'EW') : 'SY'}</span>
									<span class="actor-text">
										<span class="actor-name">{who}</span>
										<span class="actor-kind">{actorKind(e)}</span>
									</span>
								</span>
								<span class="action"
									>{actionLabel(e.action)}<span class="m-target"> · {tgt}</span></span
								>
								<span class="target">{tgt}</span>
								<span class="reason">{e.reason ?? '—'}</span>
								<span class="m-sub">{who} · {e.reason ?? tgt}</span>
								<span class="chev" aria-hidden="true"><ChevronDown size={16} /></span>
							</summary>
							<div class="aud-detail">
								<div class="panel">
									<span class="cap">Before</span>
									<pre>{lines(e.before)}</pre>
								</div>
								<div class="panel">
									<span class="cap">After</span>
									<pre class="after">{lines(e.after)}</pre>
								</div>
								<div class="panel wide">
									<span class="cap">Correlation</span>
									<pre>{e.requestId ? `req ${e.requestId}` : '—'}</pre>
								</div>
							</div>
						</details>
					</li>
				{/each}
			</ul>
		{/if}
	</section>

	{#if data.nextCursor || f.cursor}
		<div class="admin-more">
			{#if f.cursor}<a class="btn small" href={withQuery(page.url, { cursor: null })}>Newest</a
				>{/if}
			{#if data.nextCursor}
				<a class="btn small" href={withQuery(page.url, { cursor: data.nextCursor })}>Load older</a>
			{/if}
		</div>
	{/if}
</div>

<style>
	.aud-filters {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 12px;
	}
	.aud-box {
		display: flex;
		align-items: center;
		gap: 8px;
		height: 42px;
		padding: 0 14px;
		background: var(--color-surface);
		border: 1px solid color-mix(in oklab, var(--color-border) 70%, transparent);
		border-radius: 12px;
		font-size: 13px;
		line-height: 16px;
		color: var(--color-muted);
	}
	.aud-box:focus-within {
		border-color: var(--color-accent);
	}
	.aud-box.search {
		flex: 1 1 260px;
		max-width: 300px;
	}
	.aud-box input,
	.aud-box select {
		min-width: 0;
		border: 0;
		background: transparent;
		font: inherit;
		font-weight: 500;
		color: var(--color-text);
		outline: none;
	}
	.aud-box.search input {
		flex: 1 1 auto;
		font-weight: 400;
	}
	.aud-box select {
		appearance: none;
		padding-right: 2px;
		cursor: pointer;
	}
	.aud-box select option {
		background: var(--color-surface);
		color: var(--color-text);
	}
	.aud-box .uid {
		width: 84px;
		font-family: var(--font-mono);
		font-size: 12px;
	}
	.aud-box input[type='date'] {
		width: 124px;
		color-scheme: dark;
	}
	.aud-box.chip a {
		display: flex;
		color: var(--color-muted);
	}
	.aud-box .v {
		font-weight: 500;
		color: var(--color-text);
	}
	.reset {
		font-size: 13px;
		font-weight: 500;
		color: var(--color-accent-text);
		text-decoration: none;
	}
	.aud-head,
	summary {
		display: grid;
		grid-template-columns: 110px 170px 220px 220px minmax(0, 1fr) 16px;
		align-items: center;
		gap: 16px;
		padding: 0 20px;
	}
	.aud-head {
		height: 42px;
		border-bottom: 1px solid color-mix(in oklab, var(--color-border) 40%, transparent);
		font-family: var(--font-mono);
		font-size: 11px;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: color-mix(in oklab, var(--color-muted) 80%, var(--color-canvas));
	}
	.aud-rows {
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.aud-rows li + li {
		border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
	}
	summary {
		min-height: 60px;
		list-style: none;
		cursor: pointer;
	}
	summary::-webkit-details-marker {
		display: none;
	}
	summary:hover,
	details[open] {
		background: color-mix(in oklab, var(--color-raised) 45%, transparent);
	}
	summary:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: -2px;
	}
	.time {
		font-family: var(--font-mono);
		font-size: 12px;
		line-height: 16px;
		color: var(--color-muted);
	}
	.actor {
		display: flex;
		align-items: center;
		gap: 8px;
		min-width: 0;
	}
	.mini {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 24px;
		height: 24px;
		border-radius: 999px;
		background: var(--color-raised);
		font-size: 11px; /* slice 21: nothing below 11 px */
		font-weight: 600;
		line-height: 12px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
	}
	.actor-text {
		display: flex;
		flex-direction: column;
		min-width: 0;
	}
	.actor-name {
		font-size: 13px;
		line-height: 16px;
		color: var(--color-text);
	}
	.actor-kind {
		font-size: 11px;
		line-height: 14px;
		color: var(--color-muted);
	}
	.action {
		font-size: 13px;
		font-weight: 500;
		line-height: 16px;
		color: var(--color-text);
	}
	.target {
		font-size: 13px;
		line-height: 16px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
		overflow-wrap: anywhere;
	}
	.reason {
		font-size: 13px;
		line-height: 16px;
		color: var(--color-muted);
		overflow-wrap: anywhere;
	}
	.m-target,
	.m-sub {
		display: none;
	}
	.chev {
		display: flex;
		color: var(--color-muted);
		transform: rotate(-90deg);
		transition: transform 120ms ease;
	}
	details[open] .chev {
		transform: none;
		color: var(--color-text);
	}
	.aud-detail {
		display: flex;
		gap: 16px;
		padding: 4px 20px 20px 146px;
	}
	.panel {
		display: flex;
		flex: 1 1 0;
		flex-direction: column;
		gap: 8px;
		min-width: 0;
		padding: 14px 16px;
		background: var(--color-canvas);
		border: 1px solid var(--color-border);
		border-radius: 12px;
	}
	.panel.wide {
		flex-grow: 1.2;
	}
	.cap {
		font-family: var(--font-mono);
		font-size: 11px;
		letter-spacing: 0.06em;
		line-height: 14px;
		text-transform: uppercase;
		color: var(--color-muted);
	}
	pre {
		margin: 0;
		font-family: var(--font-mono);
		font-size: 12px;
		line-height: 18px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
		white-space: pre-wrap;
		overflow-wrap: anywhere;
	}
	pre.after {
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
		.aud-box.search {
			flex: 1 1 100%;
			max-width: none;
		}
		.aud-box {
			flex: 1 1 calc(50% - 6px);
		}
		.aud-box input[type='date'] {
			flex: 1 1 auto;
			width: auto;
		}
		.aud-filters .btn {
			flex: 1 1 100%;
			min-height: 42px;
		}
		.aud-head {
			display: none;
		}
		summary {
			grid-template-columns: minmax(0, 1fr) auto;
			grid-template-areas:
				'action time'
				'sub sub';
			row-gap: 2px;
			padding: 14px 16px;
		}
		.actor,
		.target,
		.reason,
		.chev {
			display: none;
		}
		.action {
			grid-area: action;
			font-size: 14px;
			line-height: 18px;
		}
		.m-target {
			display: inline;
		}
		.time {
			grid-area: time;
			align-self: start;
			font-size: 11px;
		}
		.m-sub {
			display: block;
			grid-area: sub;
			font-size: 12px;
			line-height: 16px;
			color: var(--color-muted);
		}
		.aud-detail {
			flex-wrap: wrap;
			gap: 8px;
			padding: 0 16px 16px;
		}
		.panel {
			flex: 1 1 calc(50% - 4px);
			padding: 10px 12px;
		}
		.panel.wide {
			flex-basis: 100%;
		}
	}
</style>
