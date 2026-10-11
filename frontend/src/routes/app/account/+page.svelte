<!--
	Profile & security, Paper "App — Screens v1" B09 (desktop) / B10 (mobile):
	identity hero, Profile card (Edit), Security card (Password, Change PIN)
	and the signed-in devices. Edit profile is the Paper "App — Screens v4" Z04
	dialog (owner approved 2026-10-08; no time zone, owner decision). The
	Password row opens the signed-in change (Blueprint 14, Paper Z08).
	Blueprint 23: the profile and password date open from cache (phone masked,
	no devices or sign-ins); devices and Edit wait for the live read.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { Effect, Exit } from 'effect';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Lock from '@lucide/svelte/icons/lock';
	import { AccountRoutes, type AccountView } from '#lib/contract/account.js';
	import { Profile, RANKS } from '#lib/contract/identity.js';
	import { normalisePhone } from '#lib/phone.js';
	import { newKey } from '#lib/client/api.js';
	import RootDialog from '#lib/ui/account/RootDialog.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';
	import { Revoked } from '#lib/contract/security.js';
	import { sendAccountCommand } from '#lib/client/api.js';
	import { failureOf, followGate, loadAccount, uploadPhoto } from '#lib/client/account.js';
	import { cachedPage } from '#lib/client/page-cache.svelte.js';
	import { profilePhotoSrc, shrinkPhoto } from '#lib/client/photo.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { initials, maskPhone } from '#lib/devices.js';
	import { rankLabel, ROLE_LABELS } from '#lib/labels.js';
	import AccountHero from '#lib/ui/account/AccountHero.svelte';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import SessionList from '#lib/ui/account/SessionList.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import { shownName } from '#lib/contract/identity.js';

	const shell = getContext<Shell>('shell');
	const SELF = '/app/account';

	// Blueprint 23: kind 'account'. The kept copy has the phone masked and no
	// device sessions (their ids sign devices out) or sign-ins; it never
	// holds step-up state. Edit and the device list wait for the live read.
	const account = cachedPage(shell, {
		kind: 'account',
		load: async () => {
			const exit = await loadAccount();
			if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
			const failure = failureOf(exit);
			followGate(failure, SELF);
			return {
				ok: false,
				text: 'We couldn’t load your profile right now. Try again shortly.',
				status: failure?._tag === 'BackendError' ? failure.status : null
			};
		},
		keep: (value: AccountView): AccountView => ({
			...value,
			profile: { ...value.profile, phone: maskPhone(value.profile.phone) },
			sessions: [],
			security: { ...value.security, unusualSignIns: [] }
		})
	});
	const view = $derived(account.data);
	/** The live read arrived: what Edit and the device list need. */
	const live = $derived(view !== null && account.savedAt === null);
	const loadError = $derived(account.savedAt === null ? account.error : null);
	let notice = $state<string | null>(null);
	let busy = $state<string | null>(null);
	let now = $state(Date.now());

	const summary = $derived(
		shell.state.kind === 'ready' || shell.state.kind === 'offline' ? shell.state.summary : null
	);
	const name = $derived(view ? shownName(view.profile) : null);
	const photoSrc = $derived(profilePhotoSrc(view?.profile));
	/** Paper B09: "Changed 12 Jul 2026". */
	const passwordHint = $derived.by(() => {
		const at = view?.security.passwordChangedAt;
		if (!at) return 'Used to sign in';
		const day = new Date(at).toLocaleDateString('en-GB', {
			day: 'numeric',
			month: 'short',
			year: 'numeric'
		});
		return `Changed ${day}`;
	});
	const legalName = $derived.by(() => {
		const legal = view?.profile.identity.legalName;
		return legal ? [legal.given, ...legal.middle, legal.surname].join(' ') : null;
	});
	const roleLine = $derived(
		summary
			? `${ROLE_LABELS[summary.role]}${summary.officeName ? `, ${summary.officeName}` : ''}`
			: null
	);

	const load = () => account.reload();
	$effect(() => {
		if (account.data) now = Date.now();
	});

	// Edit profile (Z04): photo, display name, phone (locked when the NIN gave
	// it), rank. Legal name and UID never change here.
	let editing = $state(false);
	let editBusy = $state(false);
	let editError = $state<string | null>(null);
	let fieldErrors = $state<{ displayName?: string; phone?: string; photo?: string }>({});
	let photoPreview = $state<string | null>(null);
	let editKey = newKey();
	let editFor = '';
	const phoneLocked = $derived(view?.profile.phoneSource === 'nin');

	function openEdit() {
		if (!view || !live) return;
		editError = null;
		fieldErrors = {};
		photoPreview = null;
		editing = true;
	}

	function previewPhoto(event: Event) {
		const file = (event.currentTarget as HTMLInputElement).files?.[0];
		if (photoPreview) URL.revokeObjectURL(photoPreview);
		photoPreview = file ? URL.createObjectURL(file) : null;
	}

	async function saveProfile({ form }: { form: FormData }) {
		if (!view || !live || !shell.online) return;
		const displayRaw = String(form.get('displayName') ?? '').trim();
		const phoneRaw = String(form.get('phone') ?? '');
		const rank = String(form.get('rank') ?? '');
		const photo = form.get('photo');
		const errors: typeof fieldErrors = {};
		if ([...displayRaw].length > 80) errors.displayName = 'Use at most 80 characters.';
		const phone = phoneLocked ? null : phoneRaw.trim() ? normalisePhone(phoneRaw) : null;
		if (!phoneLocked && phoneRaw.trim() && !phone) errors.phone = 'Enter a valid phone number.';
		fieldErrors = errors;
		editError = null;
		if (Object.keys(errors).length) return;

		const body: Record<string, unknown> = {};
		const display = displayRaw === '' ? null : displayRaw;
		if (display !== view.profile.displayName) body.displayName = display;
		if (phone && phone !== view.profile.phone) body.phone = phone;
		if ((RANKS as readonly string[]).includes(rank) && rank !== view.profile.rank) body.rank = rank;

		editBusy = true;
		if (photo instanceof File && photo.size > 0) {
			const sent = await uploadPhoto(await shrinkPhoto(photo));
			if (Exit.isFailure(sent)) {
				editBusy = false;
				const failure = failureOf(sent);
				if (followGate(failure, SELF)) return;
				fieldErrors = {
					photo:
						failure?._tag === 'BackendError' && failure.code === 'validation_error'
							? failure.message
							: 'We couldn’t upload the photo. Try again.'
				};
				return;
			}
		}
		if (Object.keys(body).length > 0) {
			// Same edit, same key (an unknown outcome is retried with it, W-00).
			const fingerprint = JSON.stringify(body);
			if (fingerprint !== editFor) {
				editFor = fingerprint;
				editKey = newKey();
			}
			const exit = await Effect.runPromiseExit(
				sendAccountCommand(
					AccountRoutes.editProfile.path,
					'PATCH',
					{ ...body, idempotencyKey: editKey },
					Profile
				)
			);
			if (Exit.isFailure(exit)) {
				editBusy = false;
				const failure = failureOf(exit);
				if (followGate(failure, SELF)) return;
				editFor = '';
				if (failure?._tag === 'BackendError' && failure.code === 'validation_error') {
					const field = String(failure.details.field ?? '');
					fieldErrors =
						field === 'phone'
							? { phone: 'Enter a valid phone number.' }
							: { displayName: 'Use 1–80 characters.' };
					return;
				}
				editError = 'We couldn’t save your profile. Try again.';
				return;
			}
		}
		editBusy = false;
		editing = false;
		if (photoPreview) URL.revokeObjectURL(photoPreview);
		photoPreview = null;
		await load();
		// The sidebar and menus read the photo's version from the shell.
		void shell.load();
	}

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
	<CacheNote savedAt={account.savedAt} online={shell.online} failed={account.error !== null} />
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
			{#if photoSrc}<img src={photoSrc} alt="" />{:else}{initials(name) ?? ''}{/if}
		</span>
		<span class="identity">
			<h1 class="name" tabindex="-1">{name ?? 'Your profile'}</h1>
			<span class="sub">
				<span class="desk">{view?.email ? `${view.email} · ` : ''}</span>UID {view?.profile.uid ??
					'—'}{#if roleLine}<span class="mob">&nbsp;· {ROLE_LABELS[summary!.role]}</span><span
						class="desk">&nbsp;· {roleLine}</span
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
					<button type="button" class="link" disabled={!live} onclick={openEdit}>Edit</button>
				</div>
				{#snippet row(label: string, value: string | null, editable = false)}
					{#if editable}
						<button type="button" class="row" disabled={!live} onclick={openEdit}>
							<span class="label">{label}</span>
							<span class="value">{value ?? 'Not set'}</span>
							<ChevronRight size={16} strokeWidth={2} class="chev" aria-hidden="true" />
						</button>
					{:else}
						<div class="row">
							<span class="label">{label}</span>
							<span class="value">{value ?? 'Not set'}</span>
						</div>
					{/if}
				{/snippet}
				{@render row('Display name', view?.profile.displayName ?? null, true)}
				{@render row('Legal name', legalName ?? (view ? 'Not verified yet' : null))}
				{@render row('Phone', maskPhone(view?.profile.phone ?? null), true)}
				{@render row('Rank', view?.profile.rank ? rankLabel(view.profile.rank) : null, true)}
				{@render row('Email', view?.email ?? null)}
			</div>
		</section>

		<section class="group" aria-labelledby="security-heading">
			<h2 class="eyebrow" id="security-heading">Security</h2>
			<div class="card">
				<div class="card-head">
					<h2 class="card-title">Security</h2>
				</div>
				<a class="row tall" href="/app/account/password">
					<span class="stack">
						<span class="label-strong">Password</span>
						<span class="hint">{passwordHint}</span>
					</span>
					<span class="pill">Change</span>
					<ChevronRight size={16} strokeWidth={2} class="chev" aria-hidden="true" />
				</a>
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

	{#if view && live}
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

{#if view && live}
	{@const profile = view.profile}
	<RootDialog
		bind:open={editing}
		pose="dialog-profile"
		title="Edit profile"
		summary="Your UID and legal name don’t change"
		confirmLabel="Save changes"
		busy={editBusy}
		error={editError}
		onConfirm={saveProfile}
	>
		{#snippet fields()}
			<div class="photo-row">
				<span class="edit-avatar" aria-hidden="true">
					{#if photoPreview}<img src={photoPreview} alt="" />{:else if photoSrc}<img
							src={photoSrc}
							alt=""
						/>{:else}{initials(name) ?? ''}{/if}
				</span>
				<span class="photo-text">
					<label class="photo-link" for="edit-photo">Change photo</label>
					<span class="photo-hint">JPG, PNG or WebP</span>
					{#if fieldErrors.photo}<span class="edit-error">{fieldErrors.photo}</span>{/if}
				</span>
				<input
					id="edit-photo"
					class="visually-hidden"
					type="file"
					name="photo"
					accept="image/jpeg,image/png,image/webp"
					onchange={previewPhoto}
				/>
			</div>
			<div class="edit-field">
				<label class="edit-label" for="edit-display">Display name</label>
				<input
					id="edit-display"
					class="edit-input"
					name="displayName"
					maxlength="80"
					autocomplete="off"
					value={profile.displayName ?? ''}
					aria-invalid={fieldErrors.displayName ? 'true' : undefined}
				/>
				{#if fieldErrors.displayName}<span class="edit-error">{fieldErrors.displayName}</span>{/if}
			</div>
			<div class="edit-field">
				<span class="edit-label-row"
					><span class="edit-label" id="edit-legal-label">Legal name</span><span class="edit-note"
						>From your NIN</span
					></span
				>
				<span class="edit-locked" role="group" aria-labelledby="edit-legal-label"
					>{legalName ?? 'Not verified yet'}<Lock
						size={16}
						strokeWidth={2}
						aria-hidden="true"
					/></span
				>
			</div>
			<div class="edit-pair">
				<div class="edit-field">
					{#if phoneLocked}
						<span class="edit-label" id="edit-phone-label">Phone</span>
						<span class="edit-locked" role="group" aria-labelledby="edit-phone-label"
							>{maskPhone(profile.phone) ?? ''}<Lock
								size={16}
								strokeWidth={2}
								aria-hidden="true"
							/></span
						>
					{:else}
						<label class="edit-label" for="edit-phone">Phone</label>
						<input
							id="edit-phone"
							class="edit-input"
							name="phone"
							type="tel"
							autocomplete="tel"
							value={profile.phone ?? ''}
							aria-invalid={fieldErrors.phone ? 'true' : undefined}
						/>
						{#if fieldErrors.phone}<span class="edit-error">{fieldErrors.phone}</span>{/if}
					{/if}
				</div>
				<div class="edit-field">
					<label class="edit-label" for="edit-rank">Rank</label>
					<span class="edit-select">
						<WheelPicker
							id="edit-rank"
							name="rank"
							label="Rank"
							title="Your rank"
							confirmText="Set rank"
							placeholder="Choose your rank"
							searchPlaceholder="Search ranks"
							initial="Executive Manager"
							options={RANKS.map((rank) => ({ value: rank, label: rankLabel(rank) }))}
							value={profile.rank ?? null}
						/>
					</span>
				</div>
			</div>
		{/snippet}
	</RootDialog>
{/if}

<style>
	.page {
		display: flex;
		flex-direction: column;
		gap: 24px;
		/* Slice 21: side margins on phones (cards touched the screen edges). */
		padding: 8px 16px 40px;
	}

	.avatar {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 56px;
		height: 56px;
		overflow: clip;
		border: 1px solid var(--color-accent-edge);
		border-radius: var(--radius-pill);
		background: var(--color-accent-subtle);
		color: var(--color-accent-text);
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
		/* Slice 21: the label keeps its width; a long value ends in an ellipsis. */
		flex: 1 0 auto;
		font-size: 15px;
		line-height: 18px;
	}

	.value {
		min-width: 0;
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
		color: var(--color-accent-text);
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-16);
		text-decoration: none;
	}

	:global([data-theme='light']) .link {
		color: var(--color-accent-label);
	}

	button.row {
		width: 100%;
		border: 0;
		background: transparent;
		font: inherit;
		text-align: left;
		cursor: pointer;
	}

	button.link {
		border: 0;
		background: transparent;
		font: inherit;
		cursor: pointer;
	}

	/* Z04 Edit profile fields. */
	.photo-row {
		display: flex;
		align-items: center;
		gap: 14px;
	}

	.edit-avatar {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 56px;
		height: 56px;
		overflow: clip;
		border: 1px solid #5a3a2e;
		border-radius: var(--radius-pill);
		background: var(--color-accent-subtle);
		color: var(--color-accent);
		font-size: 18px;
		font-weight: var(--font-weight-semibold);
		line-height: 22px;
	}

	.edit-avatar img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.photo-text {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.photo-link {
		color: var(--color-accent);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		cursor: pointer;
	}

	.photo-row:focus-within .photo-link {
		text-decoration: underline;
	}

	.photo-hint,
	.edit-note {
		color: #a9b0b3;
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.edit-field {
		display: flex;
		flex: 1 1 0%;
		flex-direction: column;
		gap: 8px;
		min-width: 0;
	}

	.edit-pair {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.edit-label-row {
		display: flex;
		justify-content: space-between;
	}

	.edit-label {
		color: #d5dadb;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	:global([data-theme='light']) .edit-label {
		color: var(--color-text);
	}

	.edit-input,
	.edit-select :global(:is(.wp-trigger, select)) {
		width: 100%;
		height: 48px;
		padding: 0 14px;
		border: 1px solid #2a2f31;
		border-radius: 14px;
		background: #141718;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		line-height: 18px;
	}

	:global([data-theme='light']) .edit-input,
	:global([data-theme='light']) .edit-select :global(:is(.wp-trigger, select)) {
		border-color: var(--color-border);
		background: var(--color-raised);
	}

	.edit-input:focus,
	.edit-select :global(:is(.wp-trigger, select)):focus {
		outline: none;
		border-color: var(--color-accent);
	}

	.edit-input[aria-invalid='true'] {
		border-color: var(--color-danger);
	}

	.edit-select {
		display: block;
	}

	.edit-select :global(.wp-chevron) {
		color: #a9b0b3;
	}

	.edit-locked {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
		height: 48px;
		padding: 0 14px;
		border: 1px dashed #343a3c;
		border-radius: 14px;
		color: #a9b0b3;
		font-size: 15px;
		line-height: 18px;
	}

	:global([data-theme='light']) .edit-locked {
		border-color: var(--color-border);
		color: var(--color-muted);
	}

	.edit-error {
		color: var(--color-danger);
		font-size: 13px;
		line-height: 18px;
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
			/* Slice 21: keep the text on the dark side of the felt, readable. */
			flex: 0 1 auto;
			gap: 6px;
			width: auto;
			max-width: min(560px, 50%);
			align-items: flex-start;
			text-align: left;
		}

		.name {
			text-align: left;
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

		.edit-pair {
			flex-direction: row;
			gap: 12px;
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
