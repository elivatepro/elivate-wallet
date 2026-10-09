<!--
	Devices & sessions, Paper "App — Screens v2" S03 (desktop) / S04 (mobile)
	and v4 Z07. Sign out one other device or all others (W-22, Blueprint 01
	B4); their PIN windows close with them. Blueprint 14: each device's
	approximate location and the "Unusual sign-ins" list (new place or new
	device), linking to Change password.
-->
<script lang="ts">
	import { getContext, onMount } from 'svelte';
	import { Effect, Exit } from 'effect';
	import { AccountRoutes, type AccountView } from '#lib/contract/account.js';
	import { Revoked } from '#lib/contract/security.js';
	import { sendAccountCommand } from '#lib/client/api.js';
	import { failureOf, followGate, loadAccount } from '#lib/client/account.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import AccountHero from '#lib/ui/account/AccountHero.svelte';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import SessionList from '#lib/ui/account/SessionList.svelte';
	import UnusualSignIns from '#lib/ui/account/UnusualSignIns.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';

	const shell = getContext<Shell>('shell');
	const SELF = '/app/account/devices';

	let view = $state<AccountView | null>(null);
	let loadError = $state<string | null>(null);
	let notice = $state<string | null>(null);
	let busy = $state<string | null>(null);
	let now = $state(Date.now());

	const count = $derived(view?.sessions.length ?? 0);
	const devices = $derived(`${count} signed-in device${count === 1 ? '' : 's'}`);

	async function load() {
		const exit = await loadAccount();
		now = Date.now();
		if (Exit.isSuccess(exit)) {
			view = exit.value;
			loadError = null;
			return;
		}
		if (followGate(failureOf(exit), SELF)) return;
		loadError = 'We couldn’t load your devices right now. Try again shortly.';
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
		} else {
			const failure = failureOf(exit);
			if (followGate(failure, SELF)) return;
			notice =
				failure?._tag === 'BackendError' && failure.code === 'not_found'
					? 'That device was already signed out.'
					: 'We couldn’t sign that device out. Try again.';
		}
		await load();
	}
</script>

<svelte:head><title>Devices & sessions · Elivate Wallet</title></svelte:head>

<PageBar title="Devices & sessions" back="/app/account" backLabel="Back to Profile & security" />

<div class="page">
	{#if loadError}<FormAlert message={loadError} />{/if}

	<AccountHero
		pose="account-devices"
		mobile={{ width: 124, height: 168, right: 10, bottom: -18 }}
		desktop={{ width: 176, height: 236, right: 72, bottom: -22 }}
	>
		<div class="text">
			<h1 class="title" tabindex="-1">
				<span class="mob">{view ? devices : 'Devices & sessions'}</span><span class="desk"
					>Devices & sessions</span
				>
			</h1>
			{#if view}
				<p class="lead">
					{count === 1
						? '1 device signed in to your account right now.'
						: `${count} devices signed in to your account right now.`}
				</p>
			{/if}
		</div>
	</AccountHero>

	{#if notice}<p class="notice" role="status">{notice}</p>{/if}

	{#if view}
		<SessionList
			sessions={view.sessions}
			{now}
			{busy}
			disabled={!shell.online}
			heading="Active sessions"
			onRevoke={revoke}
		/>
		{#if view.security.unusualSignIns.length > 0}
			<UnusualSignIns items={view.security.unusualSignIns} />
		{/if}
	{/if}
</div>

<style>
	.page {
		display: flex;
		flex-direction: column;
		gap: 24px;
		padding: 8px 0 40px;
	}

	.text {
		display: flex;
		flex-direction: column;
		gap: 6px;
		max-width: 180px;
	}

	.title {
		color: #ffffff;
		font-size: 22px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 27px;
		outline: none;
	}

	.lead,
	.desk {
		display: none;
	}

	.lead {
		color: #d5dadb;
		font-size: 15px;
		line-height: 22px;
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

		.text {
			gap: 8px;
			max-width: none;
		}

		.title {
			font-size: 36px;
			letter-spacing: -0.03em;
			line-height: 42px;
		}

		.lead,
		.desk {
			display: block;
		}

		.mob {
			display: none;
		}
	}
</style>
