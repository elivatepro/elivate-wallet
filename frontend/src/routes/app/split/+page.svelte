<!--
	Pockets & split, Paper "App — Screens v3" L01 (edit) and L02 (reason + PIN).
	Everyone in the network can read the live split and its history; only a
	manage_allocation holder (President Team) edits. Percentages have 0.01%
	precision and must total exactly 100%; Debt never receives income (U-01).
	Changes apply to income recorded after saving; nothing already posted moves.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import Check from '@lucide/svelte/icons/check';
	import Lock from '@lucide/svelte/icons/lock';
	import Plus from '@lucide/svelte/icons/plus';
	import X from '@lucide/svelte/icons/x';
	import { SplitView } from '#lib/contract/app.js';
	import { Allocation, type Allocation as AllocationType } from '#lib/contract/ledger.js';
	import type { ApiFailure } from '#lib/contract/errors.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import { isUnknownOutcome } from '#lib/recovery.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import ConfirmDialog from '#lib/ui/app/ConfirmDialog.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';

	const shell = getContext<Shell>('shell');
	const DOTS = [
		'var(--color-accent)',
		'var(--color-success)',
		'var(--color-info)',
		'var(--color-warning)',
		'var(--color-muted)',
		'#c9a3ff'
	];

	interface Row {
		key: string;
		pocketId: string | null;
		name: string;
		percent: string;
	}

	let view = $state<SplitView | null>(null);
	let loadError = $state<string | null>(null);
	let rows = $state<Row[]>([]);
	let dialogOpen = $state(false);
	let busy = $state(false);
	let dialogError = $state<string | null>(null);
	let pinError = $state<string | null>(null);
	let saved = $state(false);
	let commandKey = newKey();

	const toRows = (a: AllocationType): Row[] =>
		a.pockets.map((p) => ({
			key: p.pocketId,
			pocketId: p.pocketId,
			name: p.name,
			percent: Number(p.percent).toFixed(2)
		}));

	async function load() {
		const exit = await Effect.runPromiseExit(getJson('/api/split', SplitView));
		if (Exit.isSuccess(exit)) {
			view = exit.value;
			rows = toRows(exit.value.allocation);
			loadError = null;
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		loadError = failure?._tag === 'BackendError' ? failure.message : 'We couldn’t load the split.';
	}

	$effect(() => {
		if (shell.state.kind === 'ready' && !view) void load();
	});

	/** "40.00" → 4000 basis points; null when not a valid 0–100 value with ≤ 2 decimals. */
	const basisPoints = (value: string): number | null => {
		if (!/^\d{1,3}(\.\d{0,2})?$/.test(value.trim())) return null;
		const bp = Math.round(Number(value) * 100);
		return bp >= 0 && bp <= 10000 ? bp : null;
	};

	const totalBp = $derived(rows.reduce((sum, r) => sum + (basisPoints(r.percent) ?? 0), 0));
	const allValid = $derived(
		rows.every(
			(r) =>
				basisPoints(r.percent) !== null && r.name.trim().length >= 1 && r.name.trim().length <= 40
		)
	);
	const original = $derived(view ? toRows(view.allocation) : []);
	const changes = $derived(
		rows
			.map((r) => {
				const before = original.find((o) => o.pocketId !== null && o.pocketId === r.pocketId);
				if (!before) return `${r.name.trim() || 'New pocket'} ${Number(r.percent || 0)}%`;
				const parts: string[] = [];
				if (before.name !== r.name.trim()) parts.push(`${before.name} → ${r.name.trim()}`);
				if (basisPoints(before.percent) !== basisPoints(r.percent)) {
					parts.push(`${r.name.trim()} ${Number(before.percent)} → ${Number(r.percent)}%`);
				}
				return parts.join(' · ');
			})
			.filter(Boolean)
	);
	const dirty = $derived(changes.length > 0 || rows.length !== original.length);
	const canSave = $derived(dirty && allValid && totalBp === 10000 && shell.canAct);
	const canEdit = $derived(!!view?.canEdit && shell.canAct);
	const live = $derived(view?.versions.find((v) => v.version === view?.allocation.version) ?? null);

	function addPocket() {
		rows.push({ key: newKey(), pocketId: null, name: '', percent: '0.00' });
	}

	function discard() {
		if (view) rows = toRows(view.allocation);
		saved = false;
	}

	function message(failure: ApiFailure | undefined): string {
		if (failure?._tag !== 'BackendError') return 'We couldn’t confirm that. Try again.';
		if (failure.code === 'conflict') return 'Someone else changed the split. Reload to see it.';
		if (failure.code === 'policy_invalid') {
			const reason = failure.details.reason;
			return reason === 'total'
				? 'The shares must add up to exactly 100%.'
				: reason === 'duplicate_name'
					? 'Two pockets can’t have the same name.'
					: 'Those pockets and shares aren’t valid.';
		}
		return failure.message;
	}

	async function save({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!view || shell.state.kind !== 'ready') return;
		busy = true;
		dialogError = null;
		pinError = null;
		const body = {
			expectedVersion: view.allocation.version,
			pockets: rows.map((r) => ({
				pocketId: r.pocketId,
				name: r.name.trim(),
				basisPoints: basisPoints(r.percent) ?? 0
			})),
			reason,
			...(pin ? { pin } : {}),
			idempotencyKey: commandKey
		};
		const exit = await Effect.runPromiseExit(
			sendCommand('/api/split', 'PUT', body, shell.state.view.workspace.membershipId, Allocation)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			dialogOpen = false;
			commandKey = newKey();
			saved = true;
			view = null;
			await load();
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		if (failure?._tag === 'BackendError') {
			if (failure.code === 'step_up_required')
				return void (pinError = 'Enter your PIN to confirm.');
			if (failure.code === 'pin_incorrect') {
				const left = Number(failure.details.attemptsRemaining);
				return void (pinError = Number.isInteger(left)
					? `That PIN is incorrect. ${left} ${left === 1 ? 'try' : 'tries'} left.`
					: 'That PIN is incorrect.');
			}
			if (failure.code === 'pin_locked') return void window.location.assign('/pin/locked');
		}
		// Unknown outcome keeps the same key for the retry (W-00, #lib/recovery); a refusal gets a new one.
		if (!isUnknownOutcome(failure)) commandKey = newKey();
		dialogError = message(failure);
	}
</script>

<svelte:head><title>Pockets &amp; split · Elivate Wallet</title></svelte:head>

{#if !view && !loadError}
	<div class="skeleton" aria-hidden="true"></div>
	<p class="visually-hidden" role="status">Loading the split</p>
{:else if loadError || !view}
	<p class="load-error" role="alert">{loadError}</p>
{:else}
	<div class="layout">
		<section class="hero-mobile" aria-hidden="true">
			<div class="shade"></div>
			<RootImage pose="split" class="hero-root" sizes="120px" eager />
			<div class="hero-text">
				<p class="hero-kicker">Version {view.allocation.version} · live</p>
				<p class="hero-title">Pockets &amp; split</p>
			</div>
		</section>

		<section class="editor" aria-labelledby="split-heading">
			<h1 id="split-heading" class="visually-hidden">Pockets &amp; split</h1>
			{#if saved}<p class="saved" role="status">
					<Check size={16} strokeWidth={2} aria-hidden="true" />Saved. New income uses version {view
						.allocation.version}.
				</p>{/if}
			<div class="cols" aria-hidden="true"><span>Pocket</span><span>Share of income</span></div>
			<ul class="rows">
				{#each rows as row, i (row.key)}
					{@const bad = basisPoints(row.percent) === null}
					<li class="row">
						<span class="dot" style:background={DOTS[i % DOTS.length]} aria-hidden="true"></span>
						{#if canEdit}
							<input
								class="name"
								aria-label={`Pocket ${i + 1} name`}
								maxlength="40"
								bind:value={row.name}
							/>
							<label class="pct" class:changed={original[i]?.percent !== row.percent} class:bad>
								<input
									inputmode="decimal"
									aria-label={`${row.name || 'Pocket'} share of income, percent`}
									bind:value={row.percent}
								/>
								<span aria-hidden="true">%</span>
							</label>
							{#if row.pocketId === null}
								<button
									type="button"
									class="remove"
									aria-label={`Remove ${row.name || 'new pocket'}`}
									onclick={() => rows.splice(i, 1)}
								>
									<X size={16} strokeWidth={1.8} />
								</button>
							{:else}
								<span class="remove-slot" aria-hidden="true"></span>
							{/if}
						{:else}
							<span class="name-text">{row.name}</span>
							<span class="pct-text">{row.percent}%</span>
						{/if}
					</li>
				{/each}
				{#if view.allocation.debt}
					<li class="row debt">
						<span class="dot" style:background="var(--color-danger)" aria-hidden="true"></span>
						<span class="name-text"
							>{view.allocation.debt.name}
							<Lock size={13} strokeWidth={1.8} aria-label="Fixed" /></span
						>
						<span class="pct-text muted">No income</span>
						{#if canEdit}<span class="remove-slot" aria-hidden="true"></span>{/if}
					</li>
				{/if}
			</ul>
			<div class="foot">
				{#if canEdit && rows.length < 11}
					<button type="button" class="add" onclick={addPocket}
						><Plus size={16} strokeWidth={1.8} aria-hidden="true" />Add pocket</button
					>
				{:else}<span></span>{/if}
				<p class="total" class:ok={totalBp === 10000} aria-live="polite">
					Total <strong>{(totalBp / 100).toFixed(2)}%</strong>
					{#if totalBp === 10000}<Check size={14} strokeWidth={2.2} aria-hidden="true" />{/if}
				</p>
			</div>
			{#if canEdit}
				<div class="buttons">
					{#if dirty}<button type="button" class="ghost" onclick={discard}>Discard</button>{/if}
					<button
						type="button"
						class="primary"
						disabled={!canSave}
						onclick={() => ((dialogError = null), (pinError = null), (dialogOpen = true))}
						>Save split</button
					>
				</div>
			{/if}
		</section>

		<aside class="side">
			<section class="versions" aria-labelledby="versions-label">
				<h2 id="versions-label" class="label">Versions</h2>
				<ul>
					{#each view.versions as v (v.policyId)}
						<li>
							<span class="v-main">{v.pockets.map((p) => Number(p.percent)).join(' / ')}</span>
							<span class="v-sub"
								>{v.source === 'default' ? 'Default at activation' : (v.reason ?? 'Changed')} · version
								{v.version}</span
							>
							{#if v.version === view.allocation.version}<span class="live">Live</span>{/if}
						</li>
					{/each}
				</ul>
			</section>
			<div class="stage" aria-hidden="true">
				<RootImage pose="split" class="stage-root" sizes="390px" />
			</div>
		</aside>
	</div>

	<ConfirmDialog
		bind:open={dialogOpen}
		title="Save the new split?"
		summary={changes.join(' · ') || undefined}
		confirmLabel="Save split"
		{busy}
		error={dialogError}
		{pinError}
		onConfirm={save}
	/>
	{#if live}<span class="visually-hidden">Live version {live.version}</span>{/if}
{/if}

<style>
	.skeleton {
		height: 420px;
		border-radius: var(--radius-24);
		background: var(--color-surface);
	}

	.load-error {
		color: var(--color-danger);
	}

	.layout {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.hero-mobile {
		position: relative;
		display: flex;
		align-items: flex-end;
		height: 150px;
		padding: 20px;
		overflow: clip;
		border-radius: 22px;
		border: 1px solid #ffffff14;
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 50% 30% / cover;
		color: #fff;
	}

	.hero-mobile .shade {
		position: absolute;
		inset: 0;
		background: linear-gradient(
			90deg,
			oklab(18.5% -0.002 -0.003 / 92%) 0%,
			oklab(18.5% -0.002 -0.003 / 0%) 100%
		);
	}

	.hero-mobile :global(.hero-root) {
		position: absolute;
		right: 8px;
		bottom: -10px;
		width: 110px;
		height: 146px;
	}

	.hero-text {
		position: relative;
	}

	.hero-kicker {
		color: #d5dadb;
		font-size: 13px;
	}

	.hero-title {
		font-size: 24px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
	}

	.editor,
	.versions {
		border-radius: var(--radius-24);
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		background: var(--color-surface);
	}

	.editor {
		padding: 16px;
	}

	.saved {
		display: flex;
		align-items: center;
		gap: 8px;
		margin-bottom: 12px;
		color: var(--color-success);
		font-size: var(--text-14);
	}

	.cols {
		display: none;
	}

	.rows {
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.row {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 56px;
	}

	.dot {
		flex-shrink: 0;
		width: 10px;
		height: 10px;
		border-radius: var(--radius-pill);
	}

	.name,
	.pct {
		height: 44px;
		border-radius: var(--radius-12);
		border: 1px solid color-mix(in oklab, var(--color-text) 12%, transparent);
		background: color-mix(in oklab, var(--color-canvas) 50%, transparent);
		color: var(--color-text);
		font: inherit;
	}

	.name {
		flex: 1;
		min-width: 0;
		padding: 0 14px;
		font-size: 15px;
	}

	.pct {
		display: flex;
		align-items: center;
		flex-shrink: 0;
		width: 108px;
		padding: 0 12px;
		font-family: var(--font-mono);
	}

	.pct input {
		width: 100%;
		min-width: 0;
		border: 0;
		background: transparent;
		color: inherit;
		font: inherit;
		font-size: 15px;
		outline: none;
	}

	.pct.changed {
		border-color: color-mix(in oklab, var(--color-accent) 60%, transparent);
	}

	.pct.bad {
		border-color: var(--color-danger);
	}

	.pct:focus-within,
	.name:focus {
		outline: none;
		border-color: var(--color-accent);
	}

	.remove,
	.remove-slot {
		flex-shrink: 0;
		width: 36px;
		height: 36px;
	}

	.remove {
		display: flex;
		align-items: center;
		justify-content: center;
		border: 0;
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}

	.name-text {
		flex: 1;
		display: flex;
		align-items: center;
		gap: 6px;
		color: var(--color-text);
		font-size: 15px;
	}

	.pct-text {
		width: 108px;
		color: var(--color-text);
		font-family: var(--font-mono);
		text-align: right;
	}

	.pct-text.muted {
		color: var(--color-muted);
		font-family: inherit;
		font-size: var(--text-14);
	}

	.foot {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		margin-top: 12px;
		padding-top: 16px;
		border-top: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
	}

	.add {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		min-height: 40px;
		padding: 0 16px;
		border-radius: var(--radius-pill);
		border: 1px dashed color-mix(in oklab, var(--color-text) 18%, transparent);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: var(--text-14);
		cursor: pointer;
	}

	.total {
		display: flex;
		align-items: center;
		gap: 8px;
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	.total strong {
		color: var(--color-danger);
		font-family: var(--font-mono);
		font-weight: var(--font-weight-regular);
	}

	.total.ok strong,
	.total.ok {
		color: var(--color-success);
	}

	.total.ok {
		color: var(--color-muted);
	}

	.total.ok :global(svg) {
		color: var(--color-success);
	}

	.buttons {
		display: flex;
		justify-content: flex-end;
		gap: 12px;
		margin-top: 20px;
	}

	.primary,
	.ghost {
		min-height: 48px;
		padding: 0 22px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.primary {
		flex: 1;
		border: 0;
		background: var(--button-primary-bg);
		box-shadow: var(--auth-button-shadow);
		color: var(--button-primary-ink);
	}

	.primary:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	.ghost {
		border: 1px solid color-mix(in oklab, var(--color-text) 20%, transparent);
		background: transparent;
		color: var(--color-text);
	}

	.side {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.versions ul {
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.label {
		padding: 16px 24px 12px;
		border-bottom: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.14em;
		text-transform: uppercase;
	}

	.versions li {
		display: grid;
		grid-template-columns: 1fr auto;
		align-items: center;
		gap: 2px 12px;
		padding: 14px 24px;
	}

	.v-main {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
	}

	.v-sub {
		grid-row: 2;
		color: var(--color-muted);
		font-size: 13px;
		overflow-wrap: anywhere;
	}

	.live {
		grid-row: 1 / 3;
		grid-column: 2;
		padding: 4px 10px;
		border-radius: var(--radius-pill);
		background: var(--color-accent-subtle);
		color: var(--color-accent-text);
		font-size: 13px;
	}

	.stage {
		display: none;
	}

	@media (min-width: 1024px) {
		.layout {
			display: grid;
			grid-template-columns: minmax(0, 660px) minmax(0, 420px);
			gap: 20px;
			align-items: start;
		}

		.hero-mobile {
			display: none;
		}

		.editor {
			padding: 28px 32px;
		}

		.cols {
			display: flex;
			justify-content: space-between;
			padding: 0 70px 12px 24px;
			color: var(--color-muted);
			font-family: var(--font-mono);
			font-size: var(--text-12);
			letter-spacing: 0.14em;
			text-transform: uppercase;
		}

		.name,
		.pct {
			height: 48px;
		}

		.pct {
			width: 140px;
		}

		.pct-text {
			width: 140px;
		}

		.primary {
			flex: 0 0 auto;
		}

		.stage {
			position: relative;
			display: block;
			height: 452px;
			overflow: clip;
			border-radius: var(--radius-24);
			border: 1px solid #ffffff14;
			background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 50% 30% / cover;
		}

		.stage :global(.stage-root) {
			position: absolute;
			left: 50%;
			bottom: 0;
			width: 340px;
			height: 453px;
			transform: translateX(-50%);
		}
	}
</style>
