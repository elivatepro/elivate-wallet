<!--
	Payout accounts, Paper "App — Screens v3" Y02 (desktop 160Q, mobile 164Q).
	The person's own accounts (W-17): verified / identity check pending,
	primary, and the 24 h cooling-off for any account after the first. Make
	primary asks for the PIN; Remove asks for a reason and the PIN. Only last-4
	is shown. Blueprint 23: the list opens from cache (last-4 and the
	"•••• 1234" mask only, never a full number), then refreshes.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { goto } from '$app/navigation';
	import { Cause, Effect, Exit, Option } from 'effect';
	import { DropdownMenu } from 'bits-ui';
	import Check from '@lucide/svelte/icons/check';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Clock from '@lucide/svelte/icons/clock';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import Hourglass from '@lucide/svelte/icons/hourglass';
	import Landmark from '@lucide/svelte/icons/landmark';
	import Plus from '@lucide/svelte/icons/plus';
	import Star from '@lucide/svelte/icons/star';
	import Replace from '@lucide/svelte/icons/replace';
	import Trash from '@lucide/svelte/icons/trash-2';
	import X from '@lucide/svelte/icons/x';
	import { PayoutAccountsView, payoutPrimaryPath, payoutRemovePath } from '#lib/contract/app.js';
	import { Confirmed, PrimarySet, type PayoutAccount } from '#lib/contract/payout.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import { cachedPage, type PageLoaded } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import {
		accountTitle,
		activeAccounts,
		canMakePrimary,
		formatAdded,
		formatUsable,
		isCoolingOff,
		isRefusal,
		nextUsableAt,
		payoutMessage,
		pinProblem
	} from '#lib/payout.js';
	import ConfirmDialog from '#lib/ui/app/ConfirmDialog.svelte';
	import RootDialog from '#lib/ui/account/RootDialog.svelte';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import { setReplaceIntent } from '#lib/client/replace-intent.js';
	import RootImage from '#lib/ui/RootImage.svelte';

	const shell = getContext<Shell>('shell');

	let now = $state(Date.now());
	let notice = $state<string | null>(null);

	type Pending = { kind: 'primary' | 'remove' | 'replace'; account: PayoutAccount };
	let pending = $state<Pending | null>(null);
	let dialogOpen = $state(false);
	let busy = $state(false);
	let dialogError = $state<string | null>(null);
	let pinError = $state<string | null>(null);
	let pinTry = $state(0);
	let commandKey = newKey();
	/** The request the current key belongs to; a different one gets a new key. */
	let keyFor = '';

	async function load(): Promise<PageLoaded<PayoutAccountsView>> {
		const exit = await Effect.runPromiseExit(getJson('/api/payout-accounts', PayoutAccountsView));
		now = Date.now();
		if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		const backend = failure?._tag === 'BackendError' ? failure : null;
		return {
			ok: false,
			text:
				backend?.code === 'no_wallet'
					? 'You don’t have a wallet in this network.'
					: (backend?.message ?? 'We couldn’t load your accounts.'),
			status: backend?.status ?? null
		};
	}

	// Blueprint 23: the list opens from cache, then refreshes. The kept copy
	// rebuilds the mask from last-4, so no more than 4 digits are ever stored.
	const view = cachedPage(shell, {
		kind: 'payout-accounts',
		load,
		keep: (value) => ({
			items: value.items.map((a) => ({ ...a, accountNumberMasked: `•••• ${a.accountLast4}` }))
		})
	});
	const items = $derived(view.data?.items ?? null);
	const loadError = $derived(view.data ? null : view.error);
	const accounts = $derived(items ? activeAccounts(items) : []);

	// Re-render when the next cooling-off ends, so the chip and actions update.
	$effect(() => {
		if (!items) return;
		const next = nextUsableAt(items, now);
		if (next === null) return;
		const timer = setTimeout(() => (now = Date.now()), Math.min(next - now + 1000, 2 ** 31 - 1));
		return () => clearTimeout(timer);
	});

	function ask(kind: Pending['kind'], account: PayoutAccount) {
		const target = `${kind}:${account.payoutAccountId}`;
		if (target !== keyFor) {
			keyFor = target;
			commandKey = newKey();
		}
		pending = { kind, account };
		dialogError = null;
		pinError = null;
		notice = null;
		dialogOpen = true;
	}

	async function confirm({ reason, pin }: { reason: string; pin: string | undefined }) {
		if (!pending || shell.state.kind !== 'ready') return;
		const { kind, account } = pending;
		if (kind === 'replace') {
			// Z05: reason + PIN here, then the lookup of the new account (W-17).
			if (!pin) return void (pinError = 'Enter your 4-digit PIN.');
			setReplaceIntent({ payoutAccountId: account.payoutAccountId, reason, pin });
			dialogOpen = false;
			await goto(`/app/payout-accounts/add?replace=${account.payoutAccountId}`);
			return;
		}
		if (kind === 'remove' && !pin) return void (pinError = 'Enter your 4-digit PIN.');
		const workspaceId = shell.state.view.workspace.membershipId;
		busy = true;
		dialogError = null;
		pinError = null;
		const exit =
			kind === 'primary'
				? await Effect.runPromiseExit(
						sendCommand(
							payoutPrimaryPath(account.payoutAccountId),
							'POST',
							{ ...(pin ? { pin } : {}), idempotencyKey: commandKey },
							workspaceId,
							PrimarySet
						)
					)
				: await Effect.runPromiseExit(
						sendCommand(
							payoutRemovePath(account.payoutAccountId),
							'POST',
							{ reason, ...(pin ? { pin } : {}), idempotencyKey: commandKey },
							workspaceId,
							Confirmed
						)
					);
		busy = false;
		if (Exit.isSuccess(exit)) {
			dialogOpen = false;
			keyFor = '';
			commandKey = newKey();
			notice =
				kind === 'primary'
					? `${accountTitle(account)} is now your primary account.`
					: `${accountTitle(account)} removed.`;
			await view.reload();
			return;
		}
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		const problem = pinProblem(failure);
		if (problem?.kind === 'locked') return void window.location.assign('/pin/locked');
		if (problem) {
			pinTry += 1;
			return void (pinError = problem.message);
		}
		// Unknown outcome keeps the same key for the retry (W-00); a refusal gets a new one.
		if (isRefusal(failure)) {
			keyFor = '';
			commandKey = newKey();
		}
		dialogError = payoutMessage(failure, kind);
	}
</script>

<svelte:head><title>Payout accounts · Elivate Wallet</title></svelte:head>

<div class="page">
	<section class="hero" aria-labelledby="payout-heading">
		<div class="shade" aria-hidden="true"></div>
		<div class="grain" aria-hidden="true"></div>
		<RootImage
			pose="payout-accounts"
			class="hero-root"
			sizes="(min-width: 1024px) 176px, 112px"
			eager
		/>
		<div class="hero-text">
			<h1 id="payout-heading">Where your money lands</h1>
			<p>Withdrawals go to your primary account.</p>
		</div>
		<a class="add hero-add" href="/app/payout-accounts/add"
			><Plus size={16} strokeWidth={2.4} aria-hidden="true" />Add bank account</a
		>
	</section>

	{#if notice}
		<p class="notice" role="status">
			<Check size={16} strokeWidth={2} aria-hidden="true" />{notice}
		</p>
	{/if}

	<CacheNote savedAt={view.savedAt} online={shell.online} failed={view.error !== null} />

	{#if !items && !loadError}
		<div class="skeleton" aria-hidden="true"></div>
		<p class="visually-hidden" role="status">Loading your accounts</p>
	{:else if loadError}
		<p class="load-error" role="alert">{loadError}</p>
	{:else if accounts.length === 0}
		<p class="empty">No bank account yet.</p>
	{:else}
		<ul class="list" aria-label="Your bank accounts">
			{#each accounts as account (account.payoutAccountId)}
				{@const cooling = isCoolingOff(account, now)}
				{@const eligible = canMakePrimary(account, now)}
				{@const title = accountTitle(account)}
				<li class="row" class:cooling class:primary={account.isPrimary}>
					<span class="tile" aria-hidden="true"><Landmark size={20} strokeWidth={1.8} /></span>
					<span class="title">{title}</span>
					<span class="sub">{account.accountName} · {account.currency}</span>
					<span class="chips">
						{#if account.nameMatch === 'matched'}
							<span class="chip ok"
								><Check size={12} strokeWidth={3} aria-hidden="true" />Verified</span
							>
						{:else if account.nameMatch === 'identity_pending'}
							<span class="chip warn"
								><Hourglass size={12} strokeWidth={2.6} aria-hidden="true" />Identity check pending</span
							>
						{:else}
							<span class="chip bad"
								><X size={12} strokeWidth={3} aria-hidden="true" />Name doesn’t match</span
							>
						{/if}
						{#if account.isPrimary}<span class="chip accent">Primary</span>{/if}
						{#if cooling && account.usableFrom}
							<span class="chip warn"
								><Clock size={12} strokeWidth={2.6} aria-hidden="true" />Cooling off ·
								<span class="desk">usable&nbsp;</span>{formatUsable(account.usableFrom)}</span
							>
						{/if}
					</span>
					<span class="side">
						{#if account.isPrimary}
							<span class="added">Added {formatAdded(account.createdAt)}</span>
						{:else if eligible}
							<button
								type="button"
								class="outline"
								disabled={!shell.canAct}
								aria-label={`Make primary: ${title}`}
								onclick={() => ask('primary', account)}>Make primary</button
							>
						{/if}
					</span>
					<DropdownMenu.Root>
						<DropdownMenu.Trigger
							class="row-menu"
							aria-label={`Options for ${title}`}
							type="button"
						>
							<span class="desk"><Ellipsis size={18} strokeWidth={2} aria-hidden="true" /></span>
							<span class="mob"><ChevronRight size={18} strokeWidth={2} aria-hidden="true" /></span>
						</DropdownMenu.Trigger>
						<DropdownMenu.Portal>
							<DropdownMenu.Content class="popover row-actions" sideOffset={6} align="end">
								<div class="menu-group">
									{#if eligible}
										<DropdownMenu.Item
											class="menu-row"
											disabled={!shell.canAct}
											onSelect={() => setTimeout(() => ask('primary', account))}
										>
											<Star size={16} strokeWidth={1.8} aria-hidden="true" />
											<span class="menu-label">Make primary</span>
										</DropdownMenu.Item>
									{/if}
									<!-- Replace (W-17): new lookup + reason + PIN. Undrawn in Paper; waits on approval. -->
									<DropdownMenu.Item
										class="menu-row"
										disabled={!shell.canAct}
										onSelect={() => setTimeout(() => ask('replace', account))}
									>
										<Replace size={16} strokeWidth={1.8} aria-hidden="true" />
										<span class="menu-label">Replace account</span>
									</DropdownMenu.Item>
									<DropdownMenu.Item
										class="menu-row danger"
										disabled={!shell.canAct}
										onSelect={() => setTimeout(() => ask('remove', account))}
									>
										<Trash size={16} strokeWidth={1.8} aria-hidden="true" />
										<span class="menu-label">Remove account</span>
									</DropdownMenu.Item>
								</div>
							</DropdownMenu.Content>
						</DropdownMenu.Portal>
					</DropdownMenu.Root>
				</li>
			{/each}
		</ul>
	{/if}

	<a class="add mobile-add" href="/app/payout-accounts/add"
		><Plus size={16} strokeWidth={2.4} aria-hidden="true" />Add bank account</a
	>
</div>

{#if pending}
	{#if pending.kind === 'primary'}
		<ConfirmDialog
			bind:open={dialogOpen}
			title="Make this your primary account?"
			summary={accountTitle(pending.account)}
			confirmLabel="Make primary"
			needsReason={false}
			{busy}
			error={dialogError}
			{pinError}
			onConfirm={confirm}
		/>
	{:else}
		<!-- Paper "App — Screens v4" Z05 (replace) / Z06 (remove): reason + PIN. -->
		<RootDialog
			bind:open={dialogOpen}
			pose={pending.kind === 'replace' ? 'dialog-replace' : 'dialog-remove'}
			title={`${pending.kind === 'replace' ? 'Replace' : 'Remove'} ${accountTitle(pending.account)}`}
			summary={pending.kind === 'replace'
				? 'You’ll look up the new account next'
				: 'Requests already sent to it stay as they are'}
			confirmLabel={pending.kind === 'replace' ? 'Continue' : 'Remove account'}
			tone={pending.kind === 'replace' ? 'accent' : 'danger'}
			needsReason
			needsPin
			{busy}
			{pinTry}
			error={dialogError}
			{pinError}
			onConfirm={confirm}
		/>
	{/if}
{/if}

<style>
	.page {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	/* Hero: the BalanceCard recipe (dark in both themes). */
	.hero {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		height: 150px;
		padding: 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 20px;
		background-color: #1a1d1e;
		background-image: url('/auth-bg/mobile-dark.jpg');
		background-size: cover;
		background-position: 50% 30%;
		background-origin: border-box;
		isolation: isolate;
		color: #f2f4f4;
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
			oklab(18.5% -0.002 -0.003 / 92%) 0%,
			oklab(18.5% -0.002 -0.003 / 50%) 60%,
			oklab(18.5% -0.002 -0.003 / 0%) 100%
		);
	}

	.grain {
		background-image: url('/auth-bg/grain-128.webp');
		background-size: 128px 128px;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}

	.hero :global(.hero-root) {
		position: absolute;
		right: 18px;
		bottom: -10px;
		width: 112px;
		height: 150px;
	}

	.hero-text {
		position: relative;
		max-width: 190px;
	}

	h1 {
		font-size: 22px;
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.02em;
		line-height: 28px;
	}

	.hero-text p {
		padding-top: 4px;
		color: #f2f4f4cc;
		font-size: 13px;
		letter-spacing: -0.01em;
		line-height: 18px;
	}

	.add {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		border-radius: var(--radius-pill);
		background: var(--button-primary-bg);
		box-shadow:
			#ffffff59 0px 1px 0px inset,
			var(--button-primary-glow) 0px 10px 28px -10px;
		color: var(--button-primary-ink);
		font-weight: var(--font-weight-semibold);
		text-decoration: none;
	}

	.hero-add {
		display: none;
	}

	.mobile-add {
		height: 52px;
		font-size: 15px;
		line-height: 18px;
	}

	.notice {
		display: flex;
		align-items: center;
		gap: 8px;
		color: var(--color-success);
		font-size: var(--text-14);
	}

	.skeleton {
		height: 240px;
		border-radius: 18px;
		background: var(--color-surface);
	}

	.load-error {
		color: var(--color-danger);
	}

	.empty {
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	/* List */
	.list {
		display: flex;
		flex-direction: column;
		margin: 0;
		padding: 0;
		overflow: clip;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 18px;
		background: var(--color-surface);
		list-style: none;
	}

	.row {
		display: grid;
		grid-template-columns: 42px minmax(0, 1fr) 44px;
		grid-template-areas:
			'tile title menu'
			'tile chips menu';
		align-items: center;
		column-gap: 14px;
		row-gap: 6px;
		padding: 16px 8px 16px 16px;
	}

	.row + .row {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.row.cooling {
		background: color-mix(in oklab, var(--color-warning) 4%, var(--color-surface));
	}

	.tile {
		grid-area: tile;
		display: flex;
		align-items: center;
		justify-content: center;
		width: 42px;
		height: 42px;
		border-radius: var(--radius-12);
		background: var(--color-raised);
		color: var(--color-text);
	}

	.primary .tile {
		background: var(--color-accent-subtle);
		color: var(--color-accent-text);
	}

	.cooling .tile {
		color: var(--color-muted);
	}

	.title {
		grid-area: title;
		align-self: end;
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.sub,
	.side,
	.desk {
		display: none;
	}

	.chips {
		grid-area: chips;
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		align-self: start;
	}

	.chip {
		--tone: var(--color-success);
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 2px 8px;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--tone) 14%, var(--color-surface));
		color: var(--tone);
		font-size: 11px;
		font-weight: var(--font-weight-medium);
		line-height: 16px;
	}

	.chip.warn {
		--tone: var(--color-warning);
	}

	.chip.bad {
		--tone: var(--color-danger);
	}

	.chip.accent {
		background: var(--color-accent-subtle);
		color: var(--color-accent-text);
	}

	.row :global(.row-menu) {
		grid-area: menu;
		display: flex;
		align-items: center;
		justify-content: center;
		width: var(--hit-min);
		height: var(--hit-min);
		border: 0;
		border-radius: 10px;
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}

	.row :global(.row-menu:hover),
	.row :global(.row-menu[data-state='open']) {
		background: var(--color-raised);
	}

	.mob {
		display: contents;
	}

	:global(.popover.row-actions) {
		min-width: 200px;
	}

	:global(.menu-row.danger) {
		color: var(--color-danger);
	}

	.outline {
		height: 36px;
		padding: 0 14px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: 16px;
		white-space: nowrap;
		cursor: pointer;
	}

	.outline:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	@media (min-width: 1024px) {
		.page {
			gap: 32px;
		}

		.hero {
			justify-content: space-between;
			gap: 24px;
			height: 220px;
			padding: 32px;
			border-radius: var(--radius-24);
		}

		.shade {
			background-image: linear-gradient(
				in oklab 90deg,
				oklab(18.5% -0.002 -0.003 / 92%) 0%,
				oklab(18.5% -0.002 -0.003 / 55%) 55%,
				oklab(18.5% -0.002 -0.003 / 0%) 100%
			);
		}

		.hero :global(.hero-root) {
			right: 56px;
			bottom: -14px;
			width: 176px;
			height: 236px;
		}

		.hero-text {
			display: flex;
			flex-direction: column;
			gap: 8px;
			max-width: none;
		}

		h1 {
			font-size: var(--text-32);
			font-weight: var(--font-weight-semibold);
			line-height: var(--leading-40);
		}

		.hero-text p {
			padding: 0;
			color: #a9b0b3;
			font-size: var(--text-14);
			letter-spacing: 0;
			line-height: var(--leading-20);
		}

		.hero-add {
			position: relative;
			display: inline-flex;
			align-self: flex-start;
			height: 44px;
			padding: 0 20px 0 16px;
			font-size: var(--text-14);
			line-height: 18px;
		}

		.mobile-add {
			display: none;
		}

		.list {
			border-radius: var(--radius-16);
		}

		.row {
			grid-template-columns: 44px 280px minmax(0, 1fr) 150px 40px;
			grid-template-areas:
				'tile title chips side menu'
				'tile sub chips side menu';
			column-gap: 16px;
			row-gap: 3px;
			padding: 20px 24px;
		}

		.tile {
			width: 44px;
			height: 44px;
		}

		.title {
			line-height: 20px;
		}

		.sub {
			grid-area: sub;
			display: block;
			align-self: start;
			color: var(--color-muted);
			font-size: 13px;
			line-height: 16px;
		}

		.chips {
			align-self: center;
			gap: 8px;
		}

		.chip {
			gap: 6px;
			padding: 4px 10px;
			font-size: var(--text-12);
		}

		.side {
			grid-area: side;
			display: flex;
			justify-content: flex-end;
		}

		.added {
			color: var(--color-muted);
			font-size: 13px;
			line-height: 16px;
			text-align: right;
		}

		.desk {
			display: contents;
		}

		.mob {
			display: none;
		}

		.row :global(.row-menu) {
			width: 40px;
			height: 40px;
		}
	}
</style>
