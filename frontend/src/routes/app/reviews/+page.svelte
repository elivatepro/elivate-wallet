<!--
	NIN reviews (Blueprint 06 Q4): people in this network whose NIN check
	failed and who asked for a leader to confirm their legal name. Blueprint 36:
	whoever holds `review_identity` (President Team always; World Team and any
	role the President Team switches on, for their office and below; one person
	through Cross-access).
	Approving locks the typed name as leader-confirmed (never "provider
	verified"). Reason + PIN for both decisions. No Paper composition yet: list
	card style shared with the other app lists.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Cause, Effect, Exit, Option } from 'effect';
	import IdCard from '@lucide/svelte/icons/id-card';
	import { PendingReviews, ReviewDecided, type PendingReview } from '#lib/contract/identity.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import { cachedPage, type PageLoaded } from '#lib/client/page-cache.svelte.js';
	import { isUnknownOutcome } from '#lib/recovery.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import ConfirmDialog from '#lib/ui/app/ConfirmDialog.svelte';
	import NoAccess from '#lib/ui/app/NoAccess.svelte';

	const shell = getContext<Shell>('shell');

	let denied = $state(false);
	let target = $state<{ review: PendingReview; decision: 'approve' | 'reject' } | null>(null);
	let dialogOpen = $state(false);
	let busy = $state(false);
	let dialogError = $state<string | null>(null);
	let pinError = $state<string | null>(null);
	let notice = $state<string | null>(null);
	let commandKey = newKey();
	// Decided here: hidden at once, before the refreshed list arrives.
	let decided = $state<readonly string[]>([]);

	async function read(): Promise<PageLoaded<ReadonlyArray<PendingReview>>> {
		const exit = await Effect.runPromiseExit(getJson('/api/nin-reviews', PendingReviews));
		if (Exit.isSuccess(exit)) {
			denied = false;
			return { ok: true, value: exit.value };
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		denied = failure?._tag === 'BackendError' && failure.code === 'authorization_denied';
		// Someone who lost access no longer sees the cached list.
		if (denied) view.clear();
		return {
			ok: false,
			text: denied
				? 'You don’t review identities in this network.'
				: 'We couldn’t load the reviews.',
			status: failure?._tag === 'BackendError' ? failure.status : null
		};
	}

	// Blueprint 23: the waiting reviews open from cache (kind 'nin-reviews';
	// NIN last 4 and legal names only), then refresh.
	const view = cachedPage(shell, { kind: 'nin-reviews', load: read });
	const reviews = $derived(view.data?.filter((r) => !decided.includes(r.reviewId)) ?? null);
	const loadError = $derived(denied || !view.data ? view.error : null);
	const load = () => view.reload();

	const legal = (r: PendingReview) =>
		[r.legalName.given, ...r.legalName.middle, r.legalName.surname].join(' ');
	const when = (iso: string) =>
		new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(
			new Date(iso)
		);

	function open(review: PendingReview, decision: 'approve' | 'reject') {
		target = { review, decision };
		dialogError = null;
		pinError = null;
		commandKey = newKey();
		dialogOpen = true;
	}

	async function decide({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!target || shell.state.kind !== 'ready') return;
		busy = true;
		dialogError = null;
		pinError = null;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				`/api/nin-reviews/${target.review.reviewId}`,
				'POST',
				{ decision: target.decision, reason, ...(pin ? { pin } : {}), idempotencyKey: commandKey },
				shell.state.view.workspace.membershipId,
				ReviewDecided
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			notice = `${exit.value.status === 'approved' ? 'Approved' : 'Rejected'}: ${legal(target.review)}.`;
			dialogOpen = false;
			decided = [...decided, target.review.reviewId];
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
			// A relayed 502 is an unknown outcome: keep the key (W-00, #lib/recovery).
			if (!isUnknownOutcome(failure)) commandKey = newKey();
			dialogError =
				failure.code === 'nin_in_use'
					? 'This NIN is already verified on another account.'
					: failure.code === 'conflict'
						? 'Someone already decided this review.'
						: failure.message;
			if (failure.code === 'conflict') void load();
			return;
		}
		dialogError = 'We couldn’t confirm that. Try again.';
	}
</script>

<svelte:head><title>NIN reviews · Elivate Wallet</title></svelte:head>

{#if denied}
	<NoAccess lead={loadError ?? undefined} plain />
{:else}
	<header class="head">
		<h1 tabindex="-1">NIN reviews</h1>
		<p class="lead">Check each name against the person’s national ID before approving.</p>
	</header>

	<CacheNote savedAt={view.savedAt} online={shell.online} failed={view.error !== null} />
	{#if notice}<p class="notice" role="status">{notice}</p>{/if}

	{#if reviews === null && !loadError}
		<div class="skeleton" aria-hidden="true"></div>
	{:else if loadError}
		<p class="empty">{loadError}</p>
	{:else if reviews && reviews.length === 0}
		<p class="empty">No reviews waiting.</p>
	{:else if reviews}
		<ul class="list">
			{#each reviews as r (r.reviewId)}
				<li class="item">
					<span class="tile" aria-hidden="true"><IdCard size={20} strokeWidth={1.6} /></span>
					<div class="text">
						<p class="name">{legal(r)}</p>
						<p class="sub">
							NIN •• {r.ninLast4} · {r.requester.uid}{r.officeName ? ` · ${r.officeName}` : ''} · {ROLE_LABELS[
								r.role
							]}
						</p>
						<p class="sub">Asked {when(r.requestedAt)}</p>
					</div>
					<div class="actions">
						<button
							type="button"
							class="ghost"
							disabled={!shell.canAct}
							onclick={() => open(r, 'reject')}>Reject</button
						>
						<button
							type="button"
							class="primary"
							disabled={!shell.canAct}
							onclick={() => open(r, 'approve')}>Approve</button
						>
					</div>
				</li>
			{/each}
		</ul>
	{/if}
{/if}
{#if target}
	<ConfirmDialog
		bind:open={dialogOpen}
		title={target.decision === 'approve' ? 'Approve this name?' : 'Reject this review?'}
		summary={`${legal(target.review)} · NIN •• ${target.review.ninLast4}`}
		confirmLabel={target.decision === 'approve' ? 'Approve' : 'Reject'}
		tone={target.decision === 'approve' ? 'accent' : 'danger'}
		{busy}
		error={dialogError}
		{pinError}
		onConfirm={decide}
	/>
{/if}

<style>
	.head {
		display: flex;
		flex-direction: column;
		gap: 6px;
		margin-bottom: 20px;
	}

	h1 {
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 36px;
		outline: none;
	}

	.lead,
	.sub {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.notice {
		margin-bottom: 16px;
		color: var(--color-success);
		font-size: var(--text-14);
	}

	.skeleton {
		height: 200px;
		border-radius: var(--radius-24);
		background: var(--color-surface);
	}

	.empty {
		padding: 24px;
		border-radius: var(--radius-16);
		border: 1px dashed color-mix(in oklab, var(--color-text) 12%, transparent);
		color: var(--color-muted);
	}

	.list {
		margin: 0;
		padding: 0;
		list-style: none;
		border-radius: var(--radius-16);
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		background: var(--color-surface);
	}

	.item {
		display: grid;
		grid-template-columns: auto 1fr;
		gap: 12px 14px;
		padding: 16px 18px;
	}

	.item + .item {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.tile {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 44px;
		height: 44px;
		border-radius: var(--radius-12);
		background: color-mix(in oklab, var(--color-text) 6%, transparent);
		color: var(--color-text);
	}

	.name {
		color: var(--color-text);
		font-size: 16px;
		font-weight: var(--font-weight-semibold);
		line-height: 22px;
	}

	.actions {
		display: flex;
		grid-column: 1 / -1;
		gap: 10px;
	}

	.primary,
	.ghost {
		flex: 1;
		min-height: 44px;
		padding: 0 18px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.primary {
		border: 0;
		background: var(--button-primary-bg);
		color: var(--button-primary-ink);
	}

	.ghost {
		border: 1px solid color-mix(in oklab, var(--color-text) 20%, transparent);
		background: transparent;
		color: var(--color-text);
	}

	.primary:disabled,
	.ghost:disabled {
		opacity: var(--opacity-disabled);
	}

	@media (min-width: 1024px) {
		.item {
			grid-template-columns: auto 1fr auto;
			align-items: center;
		}

		.actions {
			grid-column: auto;
		}

		.primary,
		.ghost {
			flex: 0 0 auto;
		}
	}
</style>
