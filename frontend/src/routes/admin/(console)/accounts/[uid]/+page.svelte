<!-- Paper "Admin — Screens v1" A09 / A10 · Account detail, A09b · Change account status. -->
<script lang="ts">
	import { page } from '$app/state';
	import Shield from '@lucide/svelte/icons/shield';
	import AdminDialog from '#lib/ui/admin/AdminDialog.svelte';
	import Badge from '#lib/ui/admin/Badge.svelte';
	import NetHero from '#lib/ui/admin/NetHero.svelte';
	import {
		ACCOUNT_STATUS_LABELS,
		ACCOUNT_TONES,
		ROLE_NAMES,
		day,
		initials,
		when,
		withQuery
	} from '#lib/admin.js';
	import { PIN_LABELS, statusAction, statusChoices } from '#lib/admin-networks.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	type FormState = { error?: string; reason?: string; key?: string; status?: string };
	const fv = $derived(form as FormState | null | undefined);
	const a = $derived(data.account);
	const dialog = $derived(page.url.searchParams.get('dialog'));
	const closeHref = $derived(withQuery(page.url, { dialog: null }));
	const choices = $derived(statusChoices(a.status));
	let target = $state<string | null>(null);
	const chosen = $derived((target ?? fv?.status ?? choices[0]) as (typeof choices)[number]);
	const action = $derived(statusAction(chosen));
	const membershipTone = { active: 'success', suspended: 'warning', ended: 'neutral' } as const;
</script>

<div class="admin-page">
	<NetHero
		pose="admin-account"
		title={a.name ?? a.uid}
		status={ACCOUNT_STATUS_LABELS[a.status]}
		tone={ACCOUNT_TONES[a.status]}
		avatar={initials(a.name)}
	>
		{#snippet line()}
			<span class="mono">{a.uid}</span>{a.email ? ` · ${a.email}` : ''}{a.isAdmin
				? ' · Platform admin'
				: ''}
		{/snippet}
		{#snippet actions()}
			<a class="btn" href={withQuery(page.url, { dialog: 'status' })}>
				<Shield size={14} aria-hidden="true" />Change account status
			</a>
			<a class="btn" href={`/admin/audit?actor=${a.uid}`}>Account audit</a>
		{/snippet}
	</NetHero>

	<div class="two-col">
		<div class="stack">
			<section class="admin-card" aria-labelledby="mem-head">
				<div class="card-head"><h2 id="mem-head">Memberships</h2></div>
				{#if a.memberships.length === 0}
					<p class="admin-empty">No memberships.</p>
				{:else}
					<table class="admin-table collapse">
						<thead><tr><th>Network · office</th><th>Role</th><th>Membership</th></tr></thead>
						<tbody>
							{#each a.memberships as m (m.membershipId)}
								<tr>
									<td>
										<a class="who-text row-link" href={`/admin/networks/${m.tenantId}`}>
											<span class="who-name">{m.network}</span>
											<span class="who-sub">{m.office ?? 'President Team'}</span>
										</a>
									</td>
									<td data-label="Role">{ROLE_NAMES[m.role]}</td>
									<td data-label="Membership">
										<Badge tone={membershipTone[m.status]}>
											{m.status === 'ended'
												? `Ended ${day(m.endedAt)}`
												: m.status === 'active'
													? 'Active'
													: 'Suspended'}
										</Badge>
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				{/if}
			</section>

			<section class="admin-card" aria-labelledby="hist-head">
				<div class="card-head">
					<h2 id="hist-head">Status history</h2>
					<span class="muted">Kept permanently</span>
				</div>
				<ol class="history">
					{#each a.statusHistory as h, i (i)}
						<li>
							<span class="date">{day(h.at)}</span>
							<span class="who-text">
								<span class="who-name">{ACCOUNT_STATUS_LABELS[h.to]}</span>
								<span class="who-sub"
									>{h.reason} · {h.actor?.name ?? h.actor?.uid ?? 'Elivate'}</span
								>
							</span>
						</li>
					{/each}
					<li>
						<span class="date">{day(a.createdAt)}</span>
						<span class="who-text">
							<span class="who-name">Active</span>
							<span class="who-sub">Account created</span>
						</span>
					</li>
				</ol>
			</section>
		</div>

		<section class="admin-card" aria-labelledby="sec-head">
			<div class="card-head"><h2 id="sec-head">Security</h2></div>
			<dl class="facts">
				<div>
					<dt>Sign-in PIN</dt>
					<dd class:bad={a.security.pin === 'locked'}>{PIN_LABELS[a.security.pin]}</dd>
				</div>
				<div>
					<dt>Active sessions</dt>
					<dd>{a.security.activeSessions}</dd>
				</div>
				<div>
					<dt>Last sign-in</dt>
					<dd>{when(a.security.lastSignInAt)}</dd>
				</div>
				<div>
					<dt>Unusual sign-ins</dt>
					<dd class:warn={a.security.unusualSignIns7d > 0}>
						{a.security.unusualSignIns7d > 0
							? `${a.security.unusualSignIns7d} this week`
							: 'None this week'}
					</dd>
				</div>
				{#if a.phone}<div>
						<dt>Phone</dt>
						<dd>{a.phone}</dd>
					</div>{/if}
			</dl>
		</section>
	</div>
</div>

{#if dialog === 'status'}
	<AdminDialog
		pose="admin-account"
		title="Change account status"
		lead={`${a.name ?? a.uid} · ${a.uid}`}
		action="?/status"
		cancelHref={closeHref}
		submitLabel={action.label}
		tone={action.danger ? 'danger' : 'primary'}
		idempotencyKey={fv?.key ?? data.statusKey}
		error={fv?.error ?? null}
		reason={fv?.reason ?? ''}
	>
		<div class="transition">
			<span class="cur">
				<span class="label">Current</span>
				<Badge tone={ACCOUNT_TONES[a.status]}>{ACCOUNT_STATUS_LABELS[a.status]}</Badge>
			</span>
			<span aria-hidden="true">→</span>
			<label class="sel">
				<span class="label">New status</span>
				<select name="status" value={chosen} onchange={(e) => (target = e.currentTarget.value)}>
					{#each choices as s (s)}<option value={s}>{ACCOUNT_STATUS_LABELS[s]}</option>{/each}
				</select>
			</label>
		</div>
	</AdminDialog>
{/if}

<style>
	.mono {
		font-family: var(--font-mono);
		font-size: 13px;
	}
	.muted {
		font-size: 13px;
		color: var(--color-muted);
	}
	.card-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 18px 24px 14px;
	}
	.history {
		margin: 0;
		padding: 0 0 8px;
		list-style: none;
	}
	.history li {
		display: flex;
		gap: 24px;
		padding: 14px 24px;
		border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
	}
	.date {
		width: 88px;
		flex-shrink: 0;
		padding-top: 2px;
		font-family: var(--font-mono);
		font-size: 11px;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--color-muted);
	}
	.facts {
		margin: 0;
	}
	.facts div {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		min-height: 43px;
		padding: 0 24px;
		border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
		font-size: 14px;
	}
	.facts dt {
		color: color-mix(in oklab, var(--color-text) 80%, var(--color-muted));
	}
	.facts dd {
		margin: 0;
		color: var(--color-text);
	}
	.facts .bad {
		color: var(--color-danger);
	}
	.facts .warn {
		color: var(--color-warning);
	}
	.transition {
		display: flex;
		align-items: center;
		gap: 16px;
		padding: 14px 16px;
		border-radius: 12px;
		border: 1px solid var(--color-border);
	}
	.cur,
	.sel {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}
	.sel {
		flex: 1 1 auto;
	}
	.label {
		font-size: 13px;
		color: var(--color-muted);
	}
	select {
		height: 40px;
		padding: 0 12px;
		border-radius: 10px;
		border: 1px solid var(--color-border);
		background: var(--color-canvas);
		font: inherit;
		font-size: 14px;
		color: var(--color-text);
	}
</style>
