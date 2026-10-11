<!--
	Team details (Blueprint 17, W-20/D-11; Paper F02/F04): team name, short
	name, support contact, optional help website (HTTPS), language and time
	zone (English (Nigeria) and WAT only for now). "Recent changes" lists the
	revisions; Restore makes a new revision from an older one. Both need the PIN.
-->
<script lang="ts">
	import '#lib/ui/settings/settings.css';
	import { getContext, untrack } from 'svelte';
	import { goto } from '$app/navigation';
	import { SettingsView, type Revision } from '#lib/contract/settings.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import { cachedPage } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { personName } from '#lib/org.js';
	import {
		buildPatch,
		checkForm,
		formOf,
		normalizePhone,
		revisionTitle,
		watDay,
		type FieldErrors,
		type SettingsForm
	} from '#lib/settings.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import OrgDialog from '#lib/ui/org/OrgDialog.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import SettingsTabs from '#lib/ui/settings/SettingsTabs.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';

	const shell = getContext<Shell>('shell');
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);
	const can = (key: string) =>
		shell.state.kind === 'ready' &&
		(shell.state.view.capabilities?.permissions ?? []).includes(key);
	const canEdit = $derived(can('manage_team_settings'));
	const canVault = $derived(canEdit || can('request_restore'));

	const LOCALES: Record<string, string> = { 'en-NG': 'English (Nigeria)' };
	const ZONES: Record<string, string> = { 'Africa/Lagos': 'Africa/Lagos (WAT)' };

	// Blueprint 23: the same cached copy as Branding (kind 'settings'), then
	// fresh. Non-editors read nothing once the shell names their permissions.
	const read = cachedPage(shell, {
		kind: 'settings',
		load: () => loadView('/api/settings', SettingsView),
		enabled: () => shell.state.kind !== 'ready' || canEdit
	});
	const view = $derived(read.data);
	let denied = $state<string | null>(null);
	const loadError = $derived(denied ?? (view ? null : read.error));
	let form = $state<SettingsForm | null>(null);
	let errors = $state<FieldErrors>({});
	let saved = $state<string | null>(null);
	let checked = false;

	// The form follows the shown view (cached, then fresh); it stays read-only
	// while the cached copy shows, so no edit is lost when fresh data arrives.
	$effect(() => {
		const shown = view;
		untrack(() => (form = shown ? formOf(shown.settings) : null));
	});

	$effect(() => {
		if (shell.state.kind !== 'ready' || checked) return;
		checked = true;
		if (!canEdit) {
			read.clear();
			if (canVault) void goto('/app/settings/backups', { replaceState: true });
			else denied = 'You don’t have access to team settings.';
		}
	});

	const editable = $derived(!!view?.canEdit);
	const writable = $derived(editable && read.savedAt === null);
	const patch = $derived.by(() => {
		if (!view || !form) return {};
		const phone = normalizePhone(form.supportPhone);
		return buildPatch(view.settings, {
			...form,
			theme: view.settings.theme,
			slogan: view.settings.slogan ?? '',
			supportPhone: phone === null ? form.supportPhone : phone
		});
	});
	const dirty = $derived(Object.keys(patch).length > 0);

	function discard() {
		if (view) form = formOf(view.settings);
		errors = {};
	}

	const save = new OrgCommand();
	let confirmOpen = $state(false);

	function openSave(event: SubmitEvent) {
		event.preventDefault();
		if (!form || !dirty || !writable) return;
		errors = checkForm(form);
		if (Object.keys(errors).length > 0) return;
		save.reset(JSON.stringify(patch));
		confirmOpen = true;
	}

	async function confirmSave({ pin }: { pin: string | undefined }) {
		if (!view || !workspaceId) return;
		const result = await save.send(
			'/api/settings',
			'PATCH',
			{ expectedRevision: view.settings.revision, fields: patch, ...(pin ? { pin } : {}) },
			workspaceId
		);
		if (!result) return;
		confirmOpen = false;
		await read.reload();
		saved = 'Saved.';
		void shell.load();
	}

	// ── Restore an older revision (W-20 rollback) ──
	const restore = new OrgCommand();
	let restoreOpen = $state(false);
	let restoring = $state<Revision | null>(null);

	function openRestore(revision: Revision) {
		restoring = revision;
		restore.reset(String(revision.revision));
		restoreOpen = true;
	}

	async function confirmRestore({ pin }: { pin: string | undefined }) {
		if (!view || !workspaceId || !restoring) return;
		const result = await restore.send(
			'/api/settings/restore',
			'POST',
			{
				expectedRevision: view.settings.revision,
				revision: restoring.revision,
				...(pin ? { pin } : {})
			},
			workspaceId
		);
		if (!result) return;
		restoreOpen = false;
		await read.reload();
		saved = `Restored revision ${restoring.revision}.`;
		void shell.load();
	}
</script>

<svelte:head><title>Team details · Elivate Wallet</title></svelte:head>

<div class="s-page">
	<SettingsTabs {canEdit} {canVault} />
	<CacheNote savedAt={read.savedAt} online={shell.online} failed={read.error !== null} />

	{#if loadError}
		<p class="s-notice bad" role="alert">{loadError}</p>
	{:else if !view || !form}
		<p class="s-notice" aria-busy="true">Loading…</p>
	{:else}
		{#if !editable}
			<p class="s-notice" role="status">
				{view.settings.name} is paused. Team details can change again once it’s renewed.
			</p>
		{/if}
		{#if saved}<p class="s-notice good" role="status">{saved}</p>{/if}
		<div class="s-body">
			<form class="s-form" onsubmit={openSave} novalidate aria-label="Team details">
				<div class="s-grid2 names">
					<div class="s-field">
						<label class="s-field-head" for="team-name">Team name</label>
						<input
							id="team-name"
							class="s-input"
							maxlength="100"
							autocomplete="organization"
							bind:value={form.name}
							disabled={!writable}
							aria-invalid={errors.name ? 'true' : undefined}
							aria-describedby={errors.name ? 'team-name-error' : undefined}
						/>
						{#if errors.name}<p class="s-error" id="team-name-error">{errors.name}</p>{/if}
					</div>
					<div class="s-field">
						<label class="s-field-head" for="short-name">Short name</label>
						<input
							id="short-name"
							class="s-input"
							maxlength="30"
							bind:value={form.shortName}
							disabled={!writable}
							aria-invalid={errors.shortName ? 'true' : undefined}
							aria-describedby={errors.shortName ? 'short-name-error' : undefined}
						/>
						{#if errors.shortName}<p class="s-error" id="short-name-error">
								{errors.shortName}
							</p>{/if}
					</div>
				</div>

				<fieldset class="s-section" disabled={!writable}>
					<legend class="s-eyebrow">Support contact</legend>
					<div class="s-grid2">
						<div class="s-field">
							<label class="s-field-head" for="support-name">Name</label>
							<input
								id="support-name"
								class="s-input"
								maxlength="80"
								bind:value={form.supportName}
								aria-invalid={errors.supportName ? 'true' : undefined}
							/>
							{#if errors.supportName}<p class="s-error">{errors.supportName}</p>{/if}
						</div>
						<div class="s-field">
							<label class="s-field-head" for="support-email">Email</label>
							<input
								id="support-email"
								class="s-input"
								type="email"
								inputmode="email"
								autocomplete="off"
								maxlength="254"
								bind:value={form.supportEmail}
								aria-invalid={errors.supportEmail ? 'true' : undefined}
								aria-describedby={errors.supportEmail ? 'support-email-error' : undefined}
							/>
							{#if errors.supportEmail}<p class="s-error" id="support-email-error">
									{errors.supportEmail}
								</p>{/if}
						</div>
						<div class="s-field">
							<label class="s-field-head" for="support-phone">Phone</label>
							<input
								id="support-phone"
								class="s-input"
								type="tel"
								inputmode="tel"
								autocomplete="off"
								maxlength="24"
								bind:value={form.supportPhone}
								aria-invalid={errors.supportPhone ? 'true' : undefined}
								aria-describedby={errors.supportPhone ? 'support-phone-error' : undefined}
							/>
							{#if errors.supportPhone}<p class="s-error" id="support-phone-error">
									{errors.supportPhone}
								</p>{/if}
						</div>
						<div class="s-field">
							<label class="s-field-head" for="help-url"
								><span>Help website</span><span class="s-hint">Optional</span></label
							>
							<input
								id="help-url"
								class="s-input"
								type="url"
								inputmode="url"
								placeholder="https://"
								maxlength="300"
								bind:value={form.helpUrl}
								aria-invalid={errors.helpUrl ? 'true' : undefined}
								aria-describedby={errors.helpUrl ? 'help-url-error' : undefined}
							/>
							{#if errors.helpUrl}<p class="s-error" id="help-url-error">{errors.helpUrl}</p>{/if}
						</div>
					</div>
				</fieldset>

				<fieldset class="s-section" disabled={!writable}>
					<legend class="s-eyebrow">Region</legend>
					<div class="s-grid2">
						<div class="s-field">
							<label class="s-field-head" for="locale">Language</label>
							<WheelPicker
								id="locale"
								class="s-input"
								label="Language"
								options={view.options.locales.map((l) => ({ value: l, label: LOCALES[l] ?? l }))}
								value={form.locale}
								onchange={(v) => form && (form.locale = v)}
							/>
						</div>
						<div class="s-field">
							<label class="s-field-head" for="time-zone">Time zone</label>
							<WheelPicker
								id="time-zone"
								class="s-input"
								label="Time zone"
								searchPlaceholder="Search time zones"
								options={view.options.timeZones.map((z) => ({ value: z, label: ZONES[z] ?? z }))}
								value={form.timeZone}
								onchange={(v) => form && (form.timeZone = v)}
							/>
						</div>
					</div>
				</fieldset>

				<div class="s-actions">
					<button type="button" class="s-ghost" onclick={discard} disabled={!dirty}>Discard</button>
					<button type="submit" class="s-primary" disabled={!dirty || !writable || !shell.canAct}
						>Save changes</button
					>
				</div>
			</form>

			<div class="s-side">
				<section class="changes" aria-labelledby="changes-title">
					<h2 class="s-eyebrow changes-title" id="changes-title">Recent changes</h2>
					<ul class="change-list">
						{#each view.revisions as revision (revision.revision)}
							<li class="change">
								<span class="change-text">
									<span class="change-title">{revisionTitle(revision)}</span>
									<span class="change-meta"
										>{[
											revision.actor ? personName(revision.actor) : null,
											watDay(revision.createdAt),
											`revision ${revision.revision}`
										]
											.filter(Boolean)
											.join(' · ')}</span
									>
								</span>
								{#if revision.revision === view.settings.revision}
									<span class="s-pill live" data-tone="muted">Live</span>
								{:else if editable}
									<button
										type="button"
										class="s-link"
										disabled={!writable}
										onclick={() => openRestore(revision)}
										aria-label="Restore revision {revision.revision}">Restore</button
									>
								{/if}
							</li>
						{/each}
					</ul>
				</section>
				<div class="s-stage" aria-hidden="true">
					<RootImage pose="setup-name" class="s-stage-root" sizes="170px" />
				</div>
			</div>
		</div>
	{/if}
</div>

<OrgDialog
	bind:open={confirmOpen}
	pose="setup-name"
	title="Save team details?"
	subtitle="Members see the new details at once. You can restore an older version later."
	confirmLabel="Save changes"
	needsReason={false}
	busy={save.busy}
	error={save.error}
	pinError={save.pinError}
	onConfirm={confirmSave}
/>

<OrgDialog
	bind:open={restoreOpen}
	pose="setup-name"
	title="Restore revision {restoring?.revision ?? ''}?"
	subtitle="Its name, details and branding become a new revision. Nothing is deleted."
	confirmLabel="Restore"
	needsReason={false}
	busy={restore.busy}
	error={restore.error}
	pinError={restore.pinError}
	onConfirm={confirmRestore}
/>

<style>
	.changes {
		overflow: clip;
		border: 1px solid var(--color-border);
		border-radius: 24px;
		background: var(--color-surface);
	}

	.changes-title {
		margin: 0;
		padding: 22px 24px 12px;
	}

	.change-list {
		margin: 0;
		padding: 0;
		list-style: none;
		max-height: 420px;
		overflow-y: auto;
	}

	.change {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		min-height: 60px;
		padding: 10px 24px;
		border-top: 1px solid var(--color-border);
	}

	.change-text {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.change-title {
		color: var(--color-text);
		font-size: 14px;
		line-height: 18px;
	}

	.change-meta {
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
	}

	.live {
		border: 1px solid var(--color-accent-edge);
		background: var(--color-accent-subtle);
		color: var(--color-accent-label);
	}

	@media (min-width: 1024px) {
		.names {
			grid-template-columns: 2fr 1fr;
		}
	}
</style>
