<!--
	Branding (Blueprint 17, W-20; Paper F01/F03, approved draft TS02d): logo,
	square icon and light version, one of six team themes (owner answer Q3),
	slogan. "What members see" previews the theme before saving. Saving asks
	for the PIN (manage_team_settings); every save is a new revision.
-->
<script lang="ts">
	import '#lib/ui/settings/settings.css';
	import { getContext, onMount, untrack } from 'svelte';
	import { goto } from '$app/navigation';
	import Upload from '@lucide/svelte/icons/upload';
	import { SettingsView, THEME_LABELS, THEMES, type Theme } from '#lib/contract/settings.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import { CachedRead } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { buildPatch, formOf, type PendingAssets, type SettingsForm } from '#lib/settings.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import OrgDialog from '#lib/ui/org/OrgDialog.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import SettingsTabs from '#lib/ui/settings/SettingsTabs.svelte';

	const shell = getContext<Shell>('shell');
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);
	const can = (key: string) =>
		shell.state.kind === 'ready' &&
		(shell.state.view.capabilities?.permissions ?? []).includes(key);
	const canEdit = $derived(can('manage_team_settings'));
	const canVault = $derived(canEdit || can('request_restore'));

	// Blueprint 20 B6: cached first, then fresh; saving waits for the fresh view.
	const read = new CachedRead<SettingsView>('settings');
	const view = $derived(read.data);
	let loadError = $state<string | null>(null);
	let form = $state<SettingsForm | null>(null);
	let pending = $state<PendingAssets>({});
	let previews = $state<Partial<Record<'logo' | 'icon' | 'logo-light', string>>>({});
	let uploading = $state<'logo' | 'icon' | 'logo-light' | null>(null);
	let uploadError = $state<string | null>(null);
	let saved = $state<number | null>(null);
	let checked = false;

	async function load() {
		const ticket = read.begin();
		const result = await loadView('/api/settings', SettingsView);
		if (checked && !canEdit) return;
		if (result.ok) {
			if (!read.fresh(result.value, shell.scope, ticket)) return load();
			form = formOf(result.value.settings);
			loadError = null;
		} else loadError = result.text;
	}

	onMount(() => {
		if (read.show() && read.data) form = formOf(read.data.settings);
		return read.watch(() => void load());
	});
	// Starts with /api/session, not after it, and again when back online.
	$effect(() => {
		if (shell.readable) untrack(() => void load());
	});
	$effect(() => {
		if (shell.scope) read.confirm(shell.scope);
		if (shell.state.kind !== 'ready' || checked) return;
		checked = true;
		// World Team members only reach the vault (request_restore).
		if (!canEdit) {
			read.clear();
			form = null;
			if (canVault) void goto('/app/settings/backups', { replaceState: true });
			else loadError = 'You don’t have access to team settings.';
		}
	});

	const editable = $derived(!!view?.canEdit);
	// Read-only while cached data shows: the fresh view replaces the form, so
	// edits made before it arrives would be lost (Greptile P2 on PR #57). Kept
	// apart from `editable`, which alone drives the paused-network notice.
	const writable = $derived(editable && read.savedAt === null);
	const patch = $derived(
		view && form
			? buildPatch(
					view.settings,
					{ ...formOf(view.settings), theme: form.theme, slogan: form.slogan },
					pending
				)
			: {}
	);
	const dirty = $derived(Object.keys(patch).length > 0);
	const sloganLength = $derived([...(form?.slogan ?? '')].length);
	const brandName = $derived(view?.settings.name ?? '');
	const initial = $derived(brandName.trim().charAt(0).toUpperCase() || 'E');

	const assetUrl = (kind: 'logo' | 'icon' | 'logo-light') =>
		previews[kind] ??
		(view && hasAsset(kind)
			? // The network too: revisions count per network (slice 21).
				`/api/brand/${kind}?t=${shell.state.kind === 'ready' ? shell.state.view.workspace.tenantId : ''}&v=${view.settings.revision}`
			: null);
	const hasAsset = (kind: 'logo' | 'icon' | 'logo-light') =>
		!!view &&
		(kind === 'logo'
			? view.settings.hasLogo
			: kind === 'icon'
				? view.settings.hasIcon
				: view.settings.hasLogoLight);

	const KEY_OF = { logo: 'logoKey', icon: 'iconKey', 'logo-light': 'logoLightKey' } as const;

	async function upload(kind: 'logo' | 'icon' | 'logo-light', input: HTMLInputElement) {
		const file = input.files?.[0];
		input.value = '';
		if (!file || !workspaceId) return;
		uploadError = null;
		uploading = kind;
		const body = new FormData();
		body.set('kind', kind);
		body.set('file', file);
		try {
			const response = await fetch('/api/settings/assets', {
				method: 'POST',
				headers: { 'x-ew-workspace': workspaceId },
				body
			});
			const envelope = (await response.json()) as {
				ok: boolean;
				data?: { key?: string };
				error?: { message?: string };
			};
			if (envelope.ok && typeof envelope.data?.key === 'string') {
				pending = { ...pending, [KEY_OF[kind]]: envelope.data.key };
				if (previews[kind]) URL.revokeObjectURL(previews[kind]);
				previews = { ...previews, [kind]: URL.createObjectURL(file) };
				saved = null;
			} else {
				uploadError = envelope.error?.message ?? 'We couldn’t upload that image. Try again.';
			}
		} catch {
			uploadError = 'We couldn’t upload that image. Check your connection.';
		} finally {
			uploading = null;
		}
	}

	function discard() {
		if (!view) return;
		form = formOf(view.settings);
		for (const url of Object.values(previews)) if (url) URL.revokeObjectURL(url);
		previews = {};
		pending = {};
		uploadError = null;
	}

	const save = new OrgCommand();
	let confirmOpen = $state(false);

	function openSave(event: SubmitEvent) {
		event.preventDefault();
		if (!dirty || !writable) return;
		if (sloganLength > 60) return;
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
		for (const url of Object.values(previews)) if (url) URL.revokeObjectURL(url);
		previews = {};
		pending = {};
		await load();
		saved = view?.settings.revision ?? null;
		// The theme and tile follow at once (the shell re-reads the brand).
		void shell.load();
	}
</script>

<svelte:head><title>Branding · Elivate Wallet</title></svelte:head>

<div class="s-page">
	<SettingsTabs {canEdit} {canVault} />

	<CacheNote savedAt={read.savedAt} online={shell.online} failed={loadError !== null} />
	{#if loadError && !view && shell.state.kind !== 'loading'}
		<p class="s-notice bad" role="alert">{loadError}</p>
	{:else if !view || !form}
		<p class="s-notice" aria-busy="true">Loading…</p>
	{:else}
		{#if !editable}
			<p class="s-notice" role="status">
				{view.settings.name} is paused. Branding can change again once it’s renewed.
			</p>
		{/if}
		{#if saved}
			<p class="s-notice good" role="status">
				Saved. Members see the new look now (revision {saved}).
			</p>
		{/if}
		<div class="s-body">
			<form class="s-form" onsubmit={openSave} novalidate aria-label="Branding">
				<fieldset class="s-section" disabled={!writable}>
					<legend class="s-section-label">Logo</legend>
					<div class="logos">
						<label class="logo-tile main" class:filled={!!assetUrl('logo')}>
							<input
								type="file"
								accept="image/png,image/jpeg,image/webp"
								onchange={(e) => upload('logo', e.currentTarget)}
							/>
							{#if assetUrl('logo')}
								<img class="logo-img" src={assetUrl('logo')} alt="" />
							{:else}
								<span class="logo-row">
									<span class="tile" aria-hidden="true">{initial}</span>
									<span class="logo-name">{brandName}</span>
								</span>
							{/if}
							<span class="logo-caption"
								>{uploading === 'logo'
									? 'Uploading…'
									: assetUrl('logo')
										? 'Main logo · Replace'
										: 'Main logo · Upload'}</span
							>
						</label>
						<label class="logo-tile" class:filled={!!assetUrl('icon')}>
							<input
								type="file"
								accept="image/png,image/jpeg,image/webp"
								onchange={(e) => upload('icon', e.currentTarget)}
							/>
							{#if assetUrl('icon')}
								<img class="icon-img" src={assetUrl('icon')} alt="" />
							{:else}
								<span class="tile big" aria-hidden="true">{initial}</span>
							{/if}
							<span class="logo-caption">{uploading === 'icon' ? 'Uploading…' : 'Square icon'}</span
							>
						</label>
						<label class="logo-tile dashed" class:filled={!!assetUrl('logo-light')}>
							<input
								type="file"
								accept="image/png,image/jpeg,image/webp"
								onchange={(e) => upload('logo-light', e.currentTarget)}
							/>
							{#if assetUrl('logo-light')}
								<img class="logo-img light" src={assetUrl('logo-light')} alt="" />
							{:else}
								<Upload size={18} strokeWidth={1.8} aria-hidden="true" class="upload-icon" />
							{/if}
							<span class="logo-caption"
								>{uploading === 'logo-light' ? 'Uploading…' : 'Light version'}</span
							>
						</label>
					</div>
					<p class="hint">PNG, JPEG or WebP, up to 1 MB. Only members of your network see them.</p>
					{#if uploadError}<p class="s-error" role="alert">{uploadError}</p>{/if}
				</fieldset>

				<fieldset class="s-section" disabled={!writable}>
					<legend class="s-section-label">Theme</legend>
					<div class="themes">
						{#each THEMES as theme (theme)}
							<label class="theme" data-swatch={theme}>
								<input type="radio" name="theme" value={theme} bind:group={form.theme} />
								<span class="swatch" aria-hidden="true"></span>
								<span class="theme-name">{THEME_LABELS[theme as Theme]}</span>
							</label>
						{/each}
					</div>
				</fieldset>

				<div class="s-field">
					<label class="s-field-head" for="slogan"
						><span>Slogan</span><span class="s-hint">{sloganLength} / 60</span></label
					>
					<input
						id="slogan"
						class="s-input"
						maxlength="60"
						bind:value={form.slogan}
						disabled={!writable}
						aria-invalid={sloganLength > 60 ? 'true' : undefined}
					/>
				</div>

				<div class="s-actions">
					<button type="button" class="s-ghost" onclick={discard} disabled={!dirty}>Discard</button>
					<button type="submit" class="s-primary" disabled={!dirty || !writable || !shell.canAct}
						>Save changes</button
					>
				</div>
			</form>

			<div class="s-side">
				<section class="preview-card" aria-labelledby="preview-title">
					<h2 class="s-eyebrow" id="preview-title">What members see</h2>
					<div class="preview" data-team-theme={form.theme} data-theme="dark">
						<div class="p-head">
							{#if assetUrl('icon')}
								<img class="p-icon" src={assetUrl('icon')} alt="" />
							{:else}
								<span class="p-tile" aria-hidden="true">{initial}</span>
							{/if}
							<span class="p-text">
								<span class="p-name">{brandName}</span>
								{#if form.slogan.trim()}<span class="p-slogan">{form.slogan.trim()}</span>{/if}
							</span>
						</div>
						<div class="p-card" aria-hidden="true">
							<span class="p-label">Available to withdraw</span>
							<span class="p-amount">₦ ••••••</span>
						</div>
						<div class="p-buttons" aria-hidden="true">
							<span class="p-primary">Withdraw</span>
							<span class="p-ghost">Statement</span>
						</div>
					</div>
				</section>
				<div class="s-stage" aria-hidden="true">
					<RootImage pose="settings-branding" class="s-stage-root" sizes="170px" />
				</div>
			</div>
		</div>
	{/if}
</div>

<OrgDialog
	bind:open={confirmOpen}
	pose="settings-branding"
	title="Save branding?"
	subtitle="Everyone in {brandName} sees the new look at once. You can restore an older version later."
	confirmLabel="Save changes"
	needsReason={false}
	busy={save.busy}
	error={save.error}
	pinError={save.pinError}
	onConfirm={confirmSave}
/>

<style>
	.logos {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 12px;
	}

	.logo-tile {
		position: relative;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 10px;
		min-height: 108px;
		padding: 16px 12px;
		border: 1px solid var(--color-border);
		border-radius: 16px;
		background: var(--color-canvas);
		color: var(--color-muted);
		font-size: 13px;
		line-height: 16px;
		text-align: center;
		cursor: pointer;
	}

	.logo-tile.main {
		grid-column: 1 / -1;
	}

	.logo-tile.dashed {
		border-style: dashed;
	}

	.logo-tile:focus-within {
		outline: 2px solid var(--focus-ring);
		outline-offset: 2px;
	}

	.logo-tile input {
		position: absolute;
		width: 1px;
		height: 1px;
		opacity: 0;
	}

	fieldset:disabled .logo-tile {
		cursor: not-allowed;
		opacity: var(--opacity-disabled);
	}

	.logo-row {
		display: flex;
		align-items: center;
		gap: 10px;
		min-width: 0;
	}

	.logo-name {
		overflow: hidden;
		color: var(--color-text);
		font-size: 18px;
		font-weight: var(--font-weight-semibold);
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.tile {
		display: grid;
		flex-shrink: 0;
		place-items: center;
		width: 28px;
		height: 28px;
		border-radius: 8px;
		background: var(--color-accent);
		color: var(--button-primary-ink);
		font-size: 13px;
		font-weight: var(--font-weight-bold);
	}

	.tile.big {
		width: 40px;
		height: 40px;
		border-radius: 10px;
		font-size: 16px;
	}

	.logo-img {
		max-width: 100%;
		max-height: 40px;
		object-fit: contain;
	}

	.logo-img.light {
		padding: 4px 8px;
		border-radius: 8px;
		background: #f7f6f3;
	}

	.icon-img {
		width: 40px;
		height: 40px;
		border-radius: 10px;
		object-fit: cover;
	}

	.hint {
		margin: 0;
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	.themes {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 8px;
	}

	.theme {
		position: relative;
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 8px;
		min-height: 78px;
		padding: 12px 4px 10px;
		border: 1px solid var(--color-border);
		border-radius: 12px;
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
		cursor: pointer;
	}

	/* The radio covers its card, so a click anywhere selects it. */
	.theme input {
		position: absolute;
		inset: 0;
		z-index: 1;
		width: 100%;
		height: 100%;
		margin: 0;
		opacity: 0;
		cursor: pointer;
	}

	.theme:has(input:checked) {
		border-color: var(--color-text);
		background: var(--color-raised);
		color: var(--color-text);
		font-weight: var(--font-weight-semibold);
	}

	.theme:has(input:focus-visible) {
		outline: 2px solid var(--focus-ring);
		outline-offset: 2px;
	}

	fieldset:disabled .theme {
		cursor: not-allowed;
		opacity: var(--opacity-disabled);
	}

	.swatch {
		width: 32px;
		height: 32px;
		border-radius: 999px;
	}

	/* Fixed swatches: each shows its own theme, whatever is live. */
	[data-swatch='ember'] .swatch {
		background: linear-gradient(135deg, #fe9b69, #ff7f4f 55%, #ea7129);
	}
	[data-swatch='cobalt'] .swatch {
		background: linear-gradient(135deg, #86bbff, #6aacfe 55%, #539af3);
	}
	[data-swatch='fern'] .swatch {
		background: linear-gradient(135deg, #7acd98, #53c382 55%, #40b272);
	}
	[data-swatch='iris'] .swatch {
		background: linear-gradient(135deg, #bea8ff, #b194fe 55%, #a182f0);
	}
	[data-swatch='saffron'] .swatch {
		background: linear-gradient(135deg, #dbb256, #d4a004 55%, #c09109);
	}
	[data-swatch='rose'] .swatch {
		background: linear-gradient(135deg, #f897ae, #f67d9c 55%, #e36d8c);
	}

	.preview-card {
		display: flex;
		flex-direction: column;
		gap: 16px;
		padding: 24px;
		border: 1px solid var(--color-border);
		border-radius: 24px;
		background: var(--color-surface);
	}

	.preview-card h2 {
		margin: 0;
	}

	.preview {
		display: flex;
		flex-direction: column;
		gap: 12px;
		padding: 16px;
		border: 1px solid #2a2f31;
		border-radius: 18px;
		background: #111314;
		color: #f2f4f4;
	}

	.p-head {
		display: flex;
		align-items: center;
		gap: 8px;
		min-width: 0;
	}

	.p-tile,
	.p-icon {
		display: grid;
		flex-shrink: 0;
		place-items: center;
		width: 26px;
		height: 26px;
		border-radius: 7px;
		background: var(--color-accent);
		color: #14100e;
		font-size: 12px;
		font-weight: var(--font-weight-bold);
		object-fit: cover;
	}

	.p-text {
		display: flex;
		flex-direction: column;
		min-width: 0;
	}

	.p-name {
		overflow: hidden;
		font-size: 13px;
		font-weight: var(--font-weight-semibold);
		line-height: 16px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.p-slogan {
		overflow: hidden;
		color: #a9b0b3;
		font-size: 11px;
		line-height: 14px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.p-card {
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		gap: 2px;
		height: 96px;
		padding: 14px;
		border-radius: 14px;
		background: linear-gradient(
			110deg,
			#232728 0%,
			#232728 45%,
			color-mix(in srgb, var(--color-accent) 45%, #232728) 100%
		);
	}

	.p-label {
		color: #d5dadb;
		font-size: 11px;
		line-height: 14px;
	}

	.p-amount {
		font-size: 22px;
		font-weight: var(--font-weight-semibold);
		line-height: 28px;
	}

	.p-buttons {
		display: flex;
		gap: 8px;
	}

	.p-primary,
	.p-ghost {
		display: grid;
		flex: 1;
		place-items: center;
		height: 34px;
		border-radius: 999px;
		font-size: 12px;
		line-height: 16px;
	}

	.p-primary {
		background-image: var(--button-primary-bg);
		color: #14100e;
		font-weight: var(--font-weight-semibold);
	}

	.p-ghost {
		border: 1px solid #343a3c;
		color: var(--color-accent-text);
	}

	@media (min-width: 640px) {
		.logos {
			grid-template-columns: 1.6fr 1fr 1fr;
		}

		.logo-tile.main {
			grid-column: auto;
		}

		.themes {
			grid-template-columns: repeat(6, 1fr);
		}
	}
</style>
