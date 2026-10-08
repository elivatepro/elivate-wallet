<!--
	Edit profile (W-22, Blueprint 06 PATCH /identity/profile; Blueprint 10).
	NOT DRAWN IN PAPER YET: a minimal stub on the add-account card layout,
	waiting on owner approval of a composition. Editable: display name, phone
	(locked when the NIN record supplied it) and rank. Legal name, UID and
	email are not editable here (email changes go through support, A-05).
-->
<script lang="ts">
	import { getContext, onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { Effect, Exit } from 'effect';
	import { AccountRoutes, type AccountView } from '#lib/contract/account.js';
	import { Profile, RANKS } from '#lib/contract/identity.js';
	import { newKey, sendAccountCommand } from '#lib/client/api.js';
	import { failureOf, followGate, loadAccount } from '#lib/client/account.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { normalisePhone } from '#lib/phone.js';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import LockedField from '#lib/ui/auth/LockedField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import RankPicker from '#lib/ui/onboarding/RankPicker.svelte';

	const shell = getContext<Shell>('shell');
	const SELF = '/app/account/profile';

	let view = $state<AccountView | null>(null);
	let loadError = $state<string | null>(null);
	let errors = $state<{ displayName?: string; phone?: string; rank?: string }>({});
	let formError = $state<string | null>(null);
	let busy = $state(false);
	/** Kept across retries of the same edit (unknown outcome, W-00). */
	let key = newKey();
	let lastBody = '';

	const phoneLocked = $derived(view?.profile.phoneSource === 'nin');

	onMount(async () => {
		const exit = await loadAccount();
		if (Exit.isSuccess(exit)) view = exit.value;
		else if (!followGate(failureOf(exit), SELF))
			loadError = 'We couldn’t load your profile right now. Try again shortly.';
	});

	async function save(event: SubmitEvent) {
		event.preventDefault();
		if (!view || busy || !shell.online) return;
		const data = new FormData(event.currentTarget as HTMLFormElement);
		const displayRaw = String(data.get('displayName') ?? '').trim();
		const rank = String(data.get('rank') ?? '');
		const phoneRaw = String(data.get('phone') ?? '');
		const next: typeof errors = {};
		if ([...displayRaw].length > 80) next.displayName = 'Use at most 80 characters.';
		const phone = phoneLocked ? null : phoneRaw.trim() ? normalisePhone(phoneRaw) : null;
		if (!phoneLocked && phoneRaw.trim() && !phone) next.phone = 'Enter a valid phone number.';
		if (rank && !(RANKS as readonly string[]).includes(rank)) next.rank = 'Choose your rank.';
		errors = next;
		formError = null;
		if (Object.keys(next).length) return;

		const body: Record<string, unknown> = {};
		const display = displayRaw === '' ? null : displayRaw;
		if (display !== view.profile.displayName) body.displayName = display;
		if (phone && phone !== view.profile.phone) body.phone = phone;
		if (rank && rank !== view.profile.rank) body.rank = rank;
		if (Object.keys(body).length === 0) {
			await goto('/app/account');
			return;
		}
		const fingerprint = JSON.stringify(body);
		if (fingerprint !== lastBody) {
			lastBody = fingerprint;
			key = newKey();
		}
		busy = true;
		const exit = await Effect.runPromiseExit(
			sendAccountCommand(
				AccountRoutes.editProfile.path,
				'PATCH',
				{ ...body, idempotencyKey: key },
				Profile
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			await goto('/app/account');
			return;
		}
		const failure = failureOf(exit);
		if (followGate(failure, SELF)) return;
		if (failure?._tag === 'BackendError' && failure.code === 'validation_error') {
			const field = String(failure.details.field ?? '');
			errors =
				field === 'phone'
					? { phone: 'Enter a valid phone number.' }
					: field === 'rank'
						? { rank: 'Choose your rank.' }
						: { displayName: 'Use 1–80 characters.' };
			lastBody = '';
			return;
		}
		if (failure?._tag === 'BackendError' && failure.code === 'conflict') {
			errors = { phone: 'Your phone number came from your NIN record and can’t be changed here.' };
			lastBody = '';
			return;
		}
		formError = 'We couldn’t save your profile. Try again.';
	}
</script>

<svelte:head><title>Edit profile · Elivate Wallet</title></svelte:head>

<PageBar title="Edit profile" back="/app/account" backLabel="Back to Profile & security" />

<div class="page">
	<section class="card" aria-labelledby="edit-heading">
		<header>
			<h1 id="edit-heading">Edit profile</h1>
			<p>Your legal name comes from your NIN check and can’t be changed here.</p>
		</header>
		{#if loadError}<FormAlert message={loadError} />{/if}
		{#if formError}<FormAlert message={formError} />{/if}
		{#if view}
			<form onsubmit={save} novalidate>
				<Field
					id="displayName"
					name="displayName"
					label="Display name"
					placeholder="How your name shows in Wallet"
					autocomplete="off"
					maxlength={80}
					required={false}
					value={view.profile.displayName ?? ''}
					error={errors.displayName}
				/>
				{#if phoneLocked}
					<LockedField id="phone" label="Phone" value={view.profile.phone ?? ''} />
				{:else}
					<Field
						id="phone"
						name="phone"
						label="Phone"
						placeholder="0803 214 5678"
						autocomplete="tel"
						required={false}
						value={view.profile.phone ?? ''}
						error={errors.phone}
					/>
				{/if}
				<RankPicker value={view.profile.rank} error={errors.rank} />
				<PrimaryButton label="Save changes" {busy} disabled={!shell.online} />
			</form>
		{/if}
	</section>
</div>

<style>
	.page {
		display: flex;
		flex-direction: column;
		width: 100%;
		max-width: 560px;
		padding: 8px 0 40px;
	}

	.card {
		display: flex;
		flex-direction: column;
		gap: 20px;
		padding: 24px 20px;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 18px;
		background: var(--color-surface);
	}

	header {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	h1 {
		font-size: var(--text-24);
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: var(--leading-32);
	}

	header p {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	form {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	@media (min-width: 1024px) {
		.page {
			padding: 0;
		}

		.card {
			padding: 32px;
			border-radius: var(--radius-16);
		}
	}
</style>
