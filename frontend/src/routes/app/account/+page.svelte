<!--
	Profile & security, Paper "App — Screens v1" B09 (desktop) / B10 (mobile):
	identity hero, Profile card (Edit), Security card (Change PIN) and the
	signed-in devices. Only fields the backend has are shown: no time zone
	(not in the profile yet) and no password row (changing the password while
	signed in is not in this slice; recovery is on the sign-in page). Read live,
	never cached on device.
-->
<script lang="ts">
	import { getContext, onMount } from 'svelte';
	import { Effect, Exit } from 'effect';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import { AccountRoutes, type AccountView } from '#lib/contract/account.js';
	import { Revoked } from '#lib/contract/security.js';
	import { sendAccountCommand } from '#lib/client/api.js';
	import { failureOf, followGate, loadAccount } from '#lib/client/account.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { initials, maskPhone } from '#lib/devices.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import AccountHero from '#lib/ui/account/AccountHero.svelte';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import SessionList from '#lib/ui/account/SessionList.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import { shownName } from '#lib/contract/identity.js';

	const shell = getContext<Shell>('shell');
	const SELF = '/app/account';

	let view = $state<AccountView | null>(null);
	let loadError = $state<string | null>(null);
	let notice = $state<string | null>(null);
	let busy = $state<string | null>(null);
	let now = $state(Date.now());

	const summary = $derived(
		shell.state.kind === 'ready' || shell.state.kind === 'offline' ? shell.state.summary : null
	);
	const name = $derived(view ? shownName(view.profile) : null);
	const legalName = $derived.by(() => {
		const legal = view?.profile.identity.legalName;
		return legal ? [legal.given, ...legal.middle, legal.surname].join(' ') : null;
	});
	const roleLine = $derived(
		summary
			? `${ROLE_LABELS[summary.role]}${summary.officeName ? `, ${summary.officeName}` : ''}`
			: null
	);

	async function load() {
		const exit = await loadAccount();
		now = Date.now();
		if (Exit.isSuccess(exit)) {
			view = exit.value;
			loadError = null;
			return;
		}
		if (followGate(failureOf(exit), SELF)) return;
		loadError = 'We couldn’t load your profile right now. Try again shortly.';
	}

	onMount(() => {
		void load();
	});

	async function revoke(target: { sessionId: string } | { allOthers: true }) {
		if (!shell.online) return;
		busy = 'sessionId' in target ? target.sessionId : 'all';
		notice = null;
		const exit = await Effect.runPromiseExit(
			sendAccountCommand(AccountRoutes.revokeSessions.path, 'POST', target, Revoked)
		);
		busy = null;
		if (Exit.isSuccess(exit)) {
			notice =
				exit.value.revoked === 1
					? 'Signed out 1 device.'
					: `Signed out ${exit.value.revoked} devices.`;
			await load();
			return;
		}
		const failure = failureOf(exit);
		if (followGate(failure, SELF)) return;
		notice =
			failure?._tag === 'BackendError' && failure.code === 'not_found'
				? 'That device was already signed out.'
				: 'We couldn’t sign that device out. Try again.';
		await load();
	}
</script>

<svelte:head><title>Profile & security · Elivate Wallet</title></svelte:head>

<PageBar title="Profile & security" back="/app/more" backLabel="Back to More" />

<div class="page">
	{#if loadError}
		<FormAlert message={loadError} />
	{/if}

	<AccountHero
		pose="account-security"
		identity
		mobile={{ width: 112, height: 150, right: 16, bottom: -10 }}
		desktop={{ width: 150, height: 202, right: 64, bottom: -14 }}
	>
		<span class="avatar" aria-hidden="true">
			{#if view?.profile.hasPhoto}<img src="/api/profile/photo" alt="" />{:else}{initials(name) ??
					''}{/if}
		</span>
		<span class="identity">
			<h1 class="name" tabindex="-1">{name ?? 'Your profile'}</h1>
			<span class="sub">
				<span class="desk">{view?.email ? `${view.email} · ` : ''}</span>UID {view?.profile.uid ??
					'—'}{#if roleLine}<span class="mob"> · {ROLE_LABELS[summary!.role]}</span><span
						class="desk"
					>
						· {roleLine}</span
					>{/if}
			</span>
		</span>
	</AccountHero>

	<div class="columns">
		<section class="group" aria-labelledby="profile-heading">
			<h2 class="eyebrow" id="profile-heading">Profile</h2>
			<div class="card">
				<div class="card-head">
					<h2 class="card-title">Profile</h2>
					<a class="link" href="/app/account/profile">Edit</a>
				</div>
				{#snippet row(label: string, value: string | null, href?: string)}
					{#if href}
						<a class="row" {href}>
							<span class="label">{label}</span>
							<span class="value">{value ?? 'Not set'}</span>
							<ChevronRight size={16} strokeWidth={2} class="chev" aria-hidden="true" />
						</a>
					{:else}
						<div class="row">
							<span class="label">{label}</span>
							<span class="value">{value ?? 'Not set'}</span>
						</div>
					{/if}
				{/snippet}
				{@render row('Display name', view?.profile.displayName ?? null, '/app/account/profile')}
				{@render row('Legal name', legalName ?? (view ? 'Not verified yet' : null))}
				{@render row('Phone', maskPhone(view?.profile.phone ?? null), '/app/account/profile')}
				{@render row('Rank', view?.profile.rank ?? null, '/app/account/profile')}
				{@render row('Email', view?.email ?? null)}
			</div>
		</section>

		<section class="group" aria-labelledby="security-heading">
			<h2 class="eyebrow" id="security-heading">Security</h2>
			<div class="card">
				<div class="card-head">
					<h2 class="card-title">Security</h2>
				</div>
				<a class="row tall" href="/app/account/pin">
					<span class="stack">
						<span class="label-strong">Transaction PIN</span>
						<span class="hint">Used to sign in and confirm actions</span>
					</span>
					<span class="pill">Change PIN</span>
					<ChevronRight size={16} strokeWidth={2} class="chev" aria-hidden="true" />
				</a>
				<a class="row tall" href="/app/account/devices">
					<span class="stack">
						<span class="label-strong">Devices & sessions</span>
						<span class="hint">Where you’re signed in</span>
					</span>
					<span class="pill">Manage</span>
					<ChevronRight size={16} strokeWidth={2} class="chev" aria-hidden="true" />
				</a>
			</div>
		</section>
	</div>

	{#if notice}<p class="notice" role="status">{notice}</p>{/if}

	{#if view}
		<SessionList
			sessions={view.sessions}
			{now}
			{busy}
			disabled={!shell.online}
			heading="Devices and sessions"
			allOthersLabel="Sign out all other devices"
			onRevoke={revoke}
		/>
	{/if}
</div>

<style>
	.page {
		display: flex;
		flex-direction: column;
		gap: 24px;
		padding: 8px 0 40px;
	}

	.avatar {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 56px;
		height: 56px;
		overflow: clip;
		border: 1px solid #ff7f4f44;
		border-radius: var(--radius-pill);
		background: #3a251f;
		color: #ff9c77;
		font-size: 19px;
		font-weight: var(--font-weight-semibold);
		line-height: 24px;
	}

	.avatar img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.identity {
		display: flex;
		flex-direction: column;
		gap: 3px;
		width: 200px;
		min-width: 0;
	}

	.name {
		color: #f2f4f4;
		font-size: 20px;
		font-weight: var(--font-weight-semibold);
		line-height: 26px;
		outline: none;
	}

	.sub {
		color: #a9b0b3;
		font-size: 13px;
		line-height: var(--leading-16);
	}

	.desk {
		display: none;
	}

	.columns {
		display: flex;
		flex-direction: column;
		gap: 24px;
	}

	.group {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.eyebrow {
		padding-left: 4px;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.08em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.card {
		display: flex;
		flex-direction: column;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 18px;
		background: var(--color-surface);
	}

	:global([data-theme='light']) .card {
		border-color: var(--color-border);
	}

	.card-head {
		display: none;
	}

	.row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
		height: 56px;
		padding: 0 16px;
		color: var(--color-text);
		text-decoration: none;
	}

	.row.tall {
		height: 60px;
	}

	.row + .row {
		border-top: 1px solid #ffffff0a;
	}

	:global([data-theme='light']) .row + .row {
		border-top-color: var(--color-border);
	}

	.label,
	.label-strong {
		flex: 1;
		font-size: 15px;
		line-height: 18px;
	}

	.value {
		overflow: hidden;
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: 18px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.stack {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
	}

	.hint {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.row :global(.chev) {
		flex-shrink: 0;
		color: #5e686b;
	}

	.pill {
		display: none;
	}

	.link {
		color: #ff9c77;
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-16);
		text-decoration: none;
	}

	:global([data-theme='light']) .link {
		color: var(--color-accent-label);
	}

	.notice {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	@media (min-width: 1024px) {
		.page {
			padding: 0;
		}

		.avatar {
			width: 72px;
			height: 72px;
			font-size: var(--text-24);
			line-height: 28px;
		}

		.identity {
			flex: 1;
			gap: 6px;
			width: auto;
		}

		.name {
			font-size: 28px;
			letter-spacing: -0.02em;
			line-height: 34px;
		}

		.sub {
			font-size: var(--text-14);
			line-height: 18px;
		}

		.desk {
			display: inline;
		}

		.mob,
		.eyebrow,
		.row :global(.chev) {
			display: none;
		}

		.columns {
			flex-direction: row;
			align-items: flex-start;
			gap: 20px;
		}

		.group {
			flex: 1;
			min-width: 0;
		}

		.card {
			border-radius: var(--radius-16);
		}

		.card-head {
			display: flex;
			align-items: center;
			justify-content: space-between;
			padding: 18px 22px;
			border-bottom: 1px solid #ffffff0f;
		}

		:global([data-theme='light']) .card-head {
			border-bottom-color: var(--color-border);
		}

		.card-title {
			color: var(--color-text);
			font-size: var(--text-16);
			font-weight: var(--font-weight-semibold);
			line-height: var(--leading-20);
		}

		.row {
			height: auto;
			padding: 16px 22px;
		}

		.row.tall {
			height: auto;
			gap: 14px;
		}

		.label {
			color: var(--color-muted);
			font-size: var(--text-14);
		}

		.value {
			color: var(--color-text);
		}

		.label-strong {
			font-size: var(--text-14);
		}

		.pill {
			display: flex;
			align-items: center;
			height: 34px;
			padding: 0 14px;
			border: 1px solid var(--color-border);
			border-radius: var(--radius-pill);
			font-size: 13px;
			font-weight: var(--font-weight-medium);
			line-height: var(--leading-16);
		}
	}
</style>
