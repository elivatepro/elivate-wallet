<!--
	One of my withdrawals, Paper "Withdrawal follow-through v14" WF01 (phone,
	full page) and WF04 (desktop side panel). Blueprint 44 D4: the felt card
	with the stage pill, the amount and "To <Bank> •• last4" (Blueprint 46: no
	Root); Requested → Approval → Paid out (or where it stopped); From,
	For (Blueprint 40, only when given) and Reference. "Cancel withdrawal"
	only while it is requested and the member may cancel; the dialog says
	where the money goes back to (D6). Masked digits only, never evidence.
-->
<script lang="ts">
	import { getContext, untrack } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import Check from '@lucide/svelte/icons/check';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import X from '@lucide/svelte/icons/x';
	import { Withdrawal, WithdrawalAppRoutes } from '#lib/contract/withdrawals.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import { navigationStarted } from '#lib/client/pending-tap.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { withNext } from '#lib/gate.js';
	import { isUnknownOutcome } from '#lib/recovery.js';
	import { formatMoney, hiddenMoney } from '#lib/money.js';
	import {
		cancelSummary,
		debited,
		destinationTitle,
		detailPill,
		detailSteps,
		moveMessage,
		withdrawalHref
	} from '#lib/withdrawals.js';
	import RootDialog from '#lib/ui/account/RootDialog.svelte';
	import './money.css';

	let {
		id,
		variant = 'page',
		onClose,
		onChanged
	}: {
		id: string;
		variant?: 'page' | 'panel';
		onClose: () => void;
		/** After a cancel, so the list can read again. */
		onChanged?: (w: Withdrawal) => void;
	} = $props();

	const shell = getContext<Shell>('shell');

	let w = $state<Withdrawal | null>(null);
	let loadError = $state<string | null>(null);
	// A push or link for a withdrawal in another network lands here (the read is
	// this workspace's): say so and offer the switch, which opens it after
	// (Blueprint 45).
	let notFound = $state(false);

	async function load(withdrawalId: string, signal: AbortSignal) {
		const settle = w ? () => undefined : navigationStarted();
		const exit = await Effect.runPromiseExit(
			getJson(WithdrawalAppRoutes.mineOne(withdrawalId), Withdrawal, signal)
		);
		settle();
		if (signal.aborted) return;
		if (Exit.isSuccess(exit)) {
			w = exit.value;
			loadError = null;
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		if (failure?._tag === 'TransportError' && failure.reason === 'aborted') return;
		notFound = failure?._tag === 'BackendError' && failure.code === 'not_found';
		loadError = notFound
			? 'We couldn’t find that withdrawal in this workspace.'
			: 'We couldn’t load this withdrawal.';
	}

	$effect(() => {
		const current = id;
		if (!shell.readable) return;
		const ctrl = new AbortController();
		untrack(() => {
			if (w?.withdrawalId !== current) w = null;
			loadError = null;
			void load(current, ctrl.signal);
		});
		return () => ctrl.abort();
	});

	const money = (amount: string) =>
		shell.hideAmounts ? hiddenMoney('NGN') : formatMoney(amount, 'NGN');
	const pill = $derived(w ? detailPill(w) : null);
	const steps = $derived(w ? detailSteps(w) : []);
	const canCancel = $derived(!!w && w.can.cancel && w.status === 'requested');

	// ── Cancel (W03/W04 dialog; D6 summary) ──
	let dialogOpen = $state(false);
	let busy = $state(false);
	let dialogError = $state<string | null>(null);
	let cancelKey = newKey();
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);

	function askCancel() {
		dialogError = null;
		cancelKey = newKey();
		dialogOpen = true;
	}

	async function confirmCancel() {
		if (!w || !workspaceId) return;
		busy = true;
		dialogError = null;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				WithdrawalAppRoutes.cancelOwn(w.withdrawalId),
				'POST',
				{ idempotencyKey: cancelKey },
				workspaceId,
				Withdrawal
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			dialogOpen = false;
			w = exit.value;
			onChanged?.(exit.value);
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		if (failure && !isUnknownOutcome(failure)) cancelKey = newKey();
		dialogError = moveMessage(failure);
		if (failure?._tag === 'BackendError' && failure.code === 'conflict') {
			const ctrl = new AbortController();
			void load(w.withdrawalId, ctrl.signal);
		}
	}
</script>

{#snippet body()}
	{#if w && pill}
		<section class="wd-card" aria-label="Withdrawal {w.reference}">
			<div class="shade" aria-hidden="true"></div>
			<div class="grain" aria-hidden="true"></div>
			<span class="wd-pill {pill.tone}">{pill.label}</span>
			<div class="wd-figure">
				<p class="wd-amount" class:muted={w.status === 'cancelled' || w.status === 'rejected'}>
					{money(w.status === 'completed' ? debited(w) : w.amount)}
				</p>
				<p class="wd-to">To {destinationTitle(w)}</p>
			</div>
		</section>

		<ol class="wd-steps" aria-label="Progress">
			{#each steps as step, i (step.label)}
				<li
					class="wd-step {step.state}"
					aria-current={step.state === 'current' ? 'step' : undefined}
				>
					<span class="wd-rail" aria-hidden="true">
						<span class="wd-dot">
							{#if step.state === 'done'}<Check
									size={12}
									strokeWidth={3}
								/>{:else if step.state === 'stopped'}<X size={12} strokeWidth={3} />{/if}
						</span>
						{#if i < steps.length - 1}<span
								class="wd-line"
								class:lit={steps[i + 1]?.state === 'done' ||
									steps[i + 1]?.state === 'current' ||
									steps[i + 1]?.state === 'stopped'}
							></span>{/if}
					</span>
					<span class="wd-step-text">
						<span class="wd-step-label">{step.label}</span>
						{#if step.sub}<span class="wd-step-sub">{step.sub}</span>{/if}
						{#if step.note}<span class="wd-step-note">{step.note}</span>{/if}
					</span>
				</li>
			{/each}
		</ol>

		<section class="wd-details" aria-labelledby="wd-details-{variant}">
			<h2 class="wd-eyebrow" id="wd-details-{variant}">Details</h2>
			<dl class="wd-box">
				<div>
					<dt>From</dt>
					<dd>{w.pocket.name}</dd>
				</div>
				{#if w.reason}
					<div>
						<dt>For</dt>
						<dd class="for">{w.reason}</dd>
					</div>
				{/if}
				<div>
					<dt>Reference</dt>
					<dd class="mono">{w.reference}</dd>
				</div>
			</dl>
		</section>

		{#if canCancel}
			<button type="button" class="wd-cancel" disabled={!shell.canAct} onclick={askCancel}
				>Cancel withdrawal</button
			>
		{/if}
	{:else if loadError}
		<p class="wd-note" role="alert">
			{loadError}
			{#if notFound}
				<a
					class="wd-switch"
					href={withNext('/workspaces?switch', withdrawalHref(id))}
					data-sveltekit-reload>Switch workspace</a
				>
			{/if}
		</p>
	{:else}
		<div class="wd-outline" aria-busy="true">
			<p class="visually-hidden" role="status">Loading withdrawal</p>
			<span class="ew-skel wd-skel-card"></span>
			<span class="ew-skel wd-skel-line"></span>
			<span class="ew-skel wd-skel-line short"></span>
		</div>
	{/if}
{/snippet}

{#if variant === 'panel'}
	<aside class="wd-panel" aria-label="Withdrawal">
		<header class="wd-panel-head">
			<h2 class="wd-panel-title">Withdrawal</h2>
			<button type="button" class="wd-close" onclick={onClose} aria-label="Close withdrawal">
				<X size={16} strokeWidth={2} aria-hidden="true" />
			</button>
		</header>
		<div class="wd-body">{@render body()}</div>
	</aside>
{:else}
	<article class="wd-page">
		<header class="wd-nav">
			<button type="button" class="wd-back" onclick={onClose} aria-label="Back to withdrawals">
				<ChevronLeft size={22} strokeWidth={2} aria-hidden="true" />
			</button>
			<h1 class="wd-nav-title" tabindex="-1">Withdrawal</h1>
			<span class="wd-spacer" aria-hidden="true"></span>
		</header>
		<div class="wd-body">{@render body()}</div>
	</article>
{/if}

{#if w}
	<RootDialog
		bind:open={dialogOpen}
		title="Cancel this withdrawal?"
		summary={cancelSummary(w)}
		confirmLabel="Cancel withdrawal"
		cancelLabel="Keep it"
		tone="danger"
		{busy}
		error={dialogError}
		onConfirm={confirmCancel}
	/>
{/if}

<style>
	.wd-page,
	.wd-body {
		display: flex;
		flex-direction: column;
	}

	.wd-body {
		gap: 24px;
	}

	.wd-page .wd-body {
		padding: 8px 0 40px;
	}

	.wd-nav {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 4px 0 8px;
		margin-inline: -8px;
	}

	.wd-back,
	.wd-spacer {
		display: flex;
		flex-shrink: 0;
		align-items: center;
		justify-content: center;
		width: 44px;
		height: 44px;
		border: 0;
		border-radius: var(--radius-pill);
		background: none;
		color: var(--color-text);
		cursor: pointer;
	}

	.wd-nav-title,
	.wd-panel-title {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		outline: none;
	}

	/* ── Card (WF01 felt, stays dark in both themes; closes up around its text) ── */
	.wd-card {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		gap: 10px;
		flex-shrink: 0;
		padding: 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 20px;
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 50% 30% / cover;
		background-origin: border-box;
		isolation: isolate;
	}

	.shade,
	.grain {
		position: absolute;
		inset: 0;
		pointer-events: none;
	}

	.shade {
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(21.5% -0.004 -0.003 / 94%) 0%,
			oklab(21.5% -0.004 -0.003 / 55%) 62%,
			oklab(21.5% -0.004 -0.003 / 0%) 100%
		);
	}

	.grain {
		background: url('/auth-bg/grain-128.webp') 50% / 128px 128px;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}

	.wd-pill {
		position: relative;
		align-self: flex-start;
		padding: 4px 10px;
		border-radius: var(--radius-pill);
		background: #ffffff14;
		color: #d5dadb;
		font-size: 12px;
		line-height: 16px;
	}

	.wd-pill.warning {
		background: color-mix(in oklab, var(--color-warning) 12%, transparent);
		color: var(--color-warning);
	}

	.wd-pill.info {
		background: color-mix(in oklab, var(--color-info) 14%, transparent);
		color: var(--color-info);
	}

	.wd-pill.success {
		background: color-mix(in oklab, var(--color-success) 14%, transparent);
		color: var(--color-success);
	}

	.wd-pill.danger {
		background: color-mix(in oklab, var(--color-danger) 14%, transparent);
		color: var(--color-danger);
	}

	.wd-figure {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 4px;
		min-width: 0;
	}

	.wd-amount {
		color: #f2f4f4;
		font-size: 34px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 40px;
		font-variant-numeric: tabular-nums;
		white-space: nowrap;
	}

	.wd-amount.muted {
		color: #a9b0b3;
	}

	.wd-to {
		overflow: hidden;
		color: #a9b0b3;
		font-size: 13px;
		line-height: 18px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	/* ── Steps (WF01) ── */
	.wd-steps {
		display: flex;
		flex-direction: column;
		margin: 0;
		padding: 4px 4px 0;
		list-style: none;
	}

	.wd-step {
		display: flex;
		gap: 14px;
	}

	.wd-rail {
		display: flex;
		flex-direction: column;
		align-items: center;
		flex-shrink: 0;
		width: 20px;
	}

	.wd-dot {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 20px;
		height: 20px;
		border: 2px solid color-mix(in oklab, var(--color-text) 16%, var(--color-canvas));
		border-radius: var(--radius-pill);
		color: var(--color-canvas);
	}

	.wd-step.done .wd-dot {
		border: 0;
		background: var(--color-accent);
	}

	.wd-step.current .wd-dot {
		border-color: var(--color-accent);
		background: var(--color-accent-subtle);
	}

	.wd-step.current .wd-dot::after {
		content: '';
		width: 6px;
		height: 6px;
		border-radius: var(--radius-pill);
		background: var(--color-accent);
	}

	.wd-step.stopped .wd-dot {
		border: 0;
		background: var(--color-muted);
	}

	.wd-line {
		flex: 1 0 auto;
		width: 2px;
		min-height: 30px;
		background: color-mix(in oklab, var(--color-text) 16%, var(--color-canvas));
	}

	.wd-step.done .wd-line.lit {
		background: var(--color-accent);
	}

	.wd-step-text {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
		padding: 1px 0 12px;
	}

	.wd-step:last-child .wd-step-text {
		padding-bottom: 0;
	}

	.wd-step-label {
		color: var(--color-text);
		font-size: 15px;
		line-height: 18px;
	}

	.wd-step-sub {
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
	}

	.wd-step.todo .wd-step-label {
		color: var(--color-muted);
	}

	.wd-step-note {
		margin-top: 4px;
		color: var(--color-text);
		font-size: 13px;
		line-height: 18px;
		overflow-wrap: anywhere;
	}

	/* ── Details ── */
	.wd-details {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.wd-eyebrow {
		padding-left: 4px;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.08em;
		line-height: 16px;
		text-transform: uppercase;
	}

	.wd-box {
		display: flex;
		flex-direction: column;
		margin: 0;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 18px;
		background: var(--color-surface);
	}

	.wd-box div {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		min-height: 52px;
		padding: 8px 16px;
	}

	.wd-box div + div {
		border-top: 1px solid #ffffff0a;
	}

	.wd-box dt {
		flex-shrink: 0;
		color: var(--color-muted);
		font-size: 14px;
		line-height: 18px;
	}

	.wd-box dd {
		margin: 0;
		min-width: 0;
		color: var(--color-text);
		font-size: 14px;
		line-height: 18px;
		text-align: right;
		overflow-wrap: anywhere;
	}

	.wd-box dd.mono {
		font-family: var(--font-mono);
		font-size: 13px;
	}

	.wd-cancel {
		height: 52px;
		flex-shrink: 0;
		border: 1px solid color-mix(in oklab, var(--color-danger) 27%, transparent);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-danger);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		cursor: pointer;
		-webkit-tap-highlight-color: transparent;
	}

	.wd-cancel:active:not(:disabled) {
		background: color-mix(in oklab, var(--color-danger) 10%, transparent);
	}

	.wd-cancel:disabled {
		cursor: default;
		opacity: var(--opacity-disabled);
	}

	.wd-note {
		padding: 24px 4px;
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	.wd-switch {
		display: block;
		margin-top: 8px;
		color: var(--color-text);
		font-weight: 500;
	}

	.wd-outline {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.wd-skel-card {
		height: 138px;
		border-radius: 20px;
	}

	.wd-skel-line {
		height: 14px;
		width: 60%;
		border-radius: var(--radius-pill);
	}

	.wd-skel-line.short {
		width: 36%;
	}

	/* ── Desktop panel (WF04) ── */
	.wd-panel {
		display: flex;
		flex-direction: column;
		flex-shrink: 0;
		align-self: flex-start;
		position: sticky;
		top: 24px;
		width: min(460px, 42%);
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 20px;
		background: var(--color-surface);
	}

	.wd-panel-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		height: 64px;
		padding: 0 20px;
		border-bottom: 1px solid #ffffff0a;
	}

	.wd-close {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 36px;
		height: 36px;
		border: 1px solid #ffffff14;
		border-radius: var(--radius-pill);
		background: none;
		color: var(--color-muted);
		cursor: pointer;
	}

	.wd-panel .wd-body {
		padding: 24px;
	}

	:global([data-theme='light']) .wd-box,
	:global([data-theme='light']) .wd-panel,
	:global([data-theme='light']) .wd-close {
		border-color: var(--color-border);
	}
</style>
