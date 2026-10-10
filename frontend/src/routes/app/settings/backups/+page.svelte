<!--
	Team Backup Vault (Blueprint 17, W-24; Paper E09/E10, approved draft TS03d).
	Presidents (manage_team_settings) back up the whole network and download a
	backup after the PIN; backups are kept 90 days (owner answer Q2). World
	Team members (request_restore) see the list to ask for a restore. Restore
	requests are reviewed and run only by Elivate (owner answer Q1).
-->
<script lang="ts">
	import '#lib/ui/settings/settings.css';
	import { getContext } from 'svelte';
	import { Exit } from 'effect';
	import { VaultView, type Backup, type Restore } from '#lib/contract/settings.js';
	import { unlockDownloads } from '#lib/client/exports.svelte.js';
	import { loadView, OrgCommand, failureOf } from '#lib/client/org.svelte.js';
	import { cachedPage } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { describeOrgFailure, personName } from '#lib/org.js';
	import {
		BACKUP_STATUS,
		RESTORE_STATUS,
		backupRunning,
		formatBytes,
		shortChecksum,
		watDateTime
	} from '#lib/settings.js';
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
	const network = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.tenantName : ''
	);

	// Blueprint 23: the vault list opens from cache (kind 'vault', shared with
	// the restore request page), then refreshes. It holds no download links:
	// a download always asks the server after the PIN.
	const vault = cachedPage(shell, {
		kind: 'vault',
		load: () => loadView('/api/backups', VaultView)
	});
	const view = $derived(vault.data);
	const loadError = $derived(view ? null : vault.error);
	const load = () => vault.reload();

	// While a backup is being made, check again until it settles.
	$effect(() => {
		const shown = view;
		if (!shown || vault.savedAt !== null || !shown.backups.some((b) => backupRunning(b.status)))
			return;
		let stopped = false;
		let timer: ReturnType<typeof setTimeout> | undefined;
		const tick = async () => {
			await vault.reload();
			// A failed check leaves the same view: try again later.
			if (!stopped && vault.data === shown) timer = setTimeout(tick, 4000);
		};
		timer = setTimeout(tick, 4000);
		return () => {
			stopped = true;
			clearTimeout(timer);
		};
	});

	const latest = $derived(view?.backups.find((b) => b.status === 'ready') ?? null);
	const running = $derived(view?.backups.some((b) => backupRunning(b.status)) ?? false);
	const openRestore = $derived(
		view?.restores.find((r) =>
			['requested', 'validating', 'in_review', 'restoring'].includes(r.status)
		) ?? null
	);
	const peopleCount = (b: Backup) => b.counts?.people ?? null;
	const officeCount = (b: Backup) => b.counts?.offices ?? null;
	const summaryLine = (b: Backup) =>
		[
			peopleCount(b) !== null ? `${peopleCount(b)!.toLocaleString('en-NG')} people` : null,
			officeCount(b) !== null
				? `${officeCount(b)!.toLocaleString('en-NG')} ${officeCount(b) === 1 ? 'office' : 'offices'}`
				: null,
			b.recordCount !== null ? `${b.recordCount.toLocaleString('en-NG')} records` : null,
			`${formatBytes(b.byteSize)}, encrypted`
		]
			.filter(Boolean)
			.join(' · ');

	// ── Back up now ──
	const start = new OrgCommand();
	async function backUp() {
		if (!workspaceId) return;
		start.reset('start');
		const result = await start.send('/api/backups', 'POST', {}, workspaceId);
		if (result) await load();
	}

	// ── Download (PIN, then stream) ──
	let downloadOpen = $state(false);
	let downloading = $state<Backup | null>(null);
	let downloadBusy = $state(false);
	let downloadError = $state<string | null>(null);
	let downloadPinError = $state<string | null>(null);

	function openDownload(backup: Backup) {
		downloading = backup;
		downloadError = null;
		downloadPinError = null;
		downloadOpen = true;
	}

	async function confirmDownload({ pin }: { pin: string | undefined }) {
		if (!downloading) return;
		downloadBusy = true;
		downloadError = null;
		downloadPinError = null;
		try {
			if (pin) {
				const unlocked = await unlockDownloads(pin);
				if (Exit.isFailure(unlocked)) {
					const said = describeOrgFailure(failureOf(unlocked));
					if (said.kind === 'locked') window.location.assign('/pin/locked');
					else if (said.kind === 'pin') downloadPinError = said.text;
					else downloadError = said.text;
					return;
				}
			}
			const response = await fetch(`/api/backups/${downloading.backupId}/file`);
			if (!response.ok || !response.headers.get('content-type')?.includes('zip')) {
				const body = (await response.json().catch(() => null)) as {
					error?: { code?: string; message?: string };
				} | null;
				if (body?.error?.code === 'step_up_required')
					downloadPinError = 'Enter your PIN to download.';
				else downloadError = body?.error?.message ?? 'We couldn’t download that backup. Try again.';
				return;
			}
			const name =
				/filename="([^"]+)"/.exec(response.headers.get('content-disposition') ?? '')?.[1] ??
				'elivate-backup.zip';
			const url = URL.createObjectURL(await response.blob());
			const link = document.createElement('a');
			link.href = url;
			link.download = name;
			document.body.append(link);
			link.click();
			link.remove();
			setTimeout(() => URL.revokeObjectURL(url), 60_000);
			downloadOpen = false;
		} catch {
			downloadError = 'We couldn’t download that backup. Check your connection.';
		} finally {
			downloadBusy = false;
		}
	}

	// ── Cancel a restore request ──
	const cancel = new OrgCommand();
	let cancelOpen = $state(false);
	let cancelling = $state<Restore | null>(null);

	function openCancel(restore: Restore) {
		cancelling = restore;
		cancel.reset(restore.restoreId);
		cancelOpen = true;
	}

	async function confirmCancel() {
		if (!cancelling || !workspaceId) return;
		const result = await cancel.send(
			`/api/restores/${cancelling.restoreId}/cancel`,
			'POST',
			{},
			workspaceId
		);
		if (!result) return;
		cancelOpen = false;
		await load();
	}
</script>

<svelte:head><title>Backup vault · Elivate Wallet</title></svelte:head>

<div class="s-page">
	<SettingsTabs {canEdit} canVault={true} />
	<CacheNote savedAt={vault.savedAt} online={shell.online} failed={vault.error !== null} />

	{#if loadError}
		<p class="s-notice bad" role="alert">{loadError}</p>
	{:else if !view}
		<p class="s-notice" aria-busy="true">Loading…</p>
	{:else}
		<section class="hero" aria-labelledby="vault-title">
			<div class="hero-shade" aria-hidden="true"></div>
			<RootImage
				pose="backup-vault"
				class="hero-root"
				sizes="(min-width: 1024px) 190px, 120px"
				eager
			/>
			<div class="hero-text">
				{#if latest}
					<p class="hero-eyebrow">
						<span class="s-pill" data-tone="success">Complete</span>
						<span>Last backup · {network}</span>
					</p>
					<h1 id="vault-title">{watDateTime(latest.readyAt ?? latest.createdAt)}</h1>
					<p class="hero-line">{summaryLine(latest)}</p>
				{:else}
					<h1 id="vault-title">No backups yet</h1>
					<p class="hero-line">
						{view.canBackup
							? `Back up now makes a full copy of ${network} you can download.`
							: `A President can back up ${network}.`}
					</p>
				{/if}
			</div>
		</section>

		{#if start.error}<p class="s-notice bad" role="alert">{start.error}</p>{/if}

		<div class="vault-actions">
			{#if view.canBackup}
				<button
					type="button"
					class="s-primary"
					onclick={backUp}
					disabled={start.busy || running || !shell.canAct}
					>{running ? 'Backing up…' : 'Back up now'}</button
				>
				{#if latest?.canDownload}
					<button type="button" class="s-ghost" onclick={() => openDownload(latest)}
						>Download latest</button
					>
				{/if}
			{/if}
			{#if view.canRequestRestore && latest && !openRestore}
				<a class="s-ghost restore-link" href="/app/settings/backups/restore">Request a restore</a>
			{/if}
		</div>

		{#if view.backups.length > 0}
			<section class="table" aria-labelledby="backups-title">
				<h2 class="visually-hidden" id="backups-title">Backups</h2>
				<div class="row head" aria-hidden="true">
					<span class="c-main">Backup</span>
					<span class="c-size">Size</span>
					<span class="c-sum">Checksum</span>
					<span class="c-status">Status</span>
					<span class="c-act"></span>
				</div>
				<ul class="rows">
					{#each view.backups as backup (backup.backupId)}
						<li class="row">
							<span class="c-main">
								<span class="t-strong">{watDateTime(backup.readyAt ?? backup.createdAt)}</span>
								<span class="t-muted"
									>Started by {backup.startedBy
										? personName(backup.startedBy)
										: 'a President'}</span
								>
							</span>
							<span class="c-size">{formatBytes(backup.byteSize)}</span>
							<span class="c-sum s-mono">{shortChecksum(backup.sha256)}</span>
							<span class="c-status"
								><span class="s-pill" data-tone={BACKUP_STATUS[backup.status].tone}
									>{BACKUP_STATUS[backup.status].label}</span
								></span
							>
							<span class="c-act">
								{#if backup.canDownload}
									<button type="button" class="s-link" onclick={() => openDownload(backup)}
										>Download</button
									>
								{:else if view.canBackup && (backup.status === 'failed' || backup.status === 'too_large') && !running}
									<button type="button" class="s-link" onclick={backUp} disabled={start.busy}
										>Retry</button
									>
								{/if}
							</span>
						</li>
					{/each}
				</ul>
			</section>
		{/if}

		<section class="restores" aria-labelledby="restores-title">
			<div class="restores-head">
				<h2 id="restores-title">Restore requests</h2>
				<p class="t-muted">
					Elivate reviews every request. Backups are kept {view.retentionDays} days.
				</p>
			</div>
			{#if view.restores.length === 0}
				<p class="s-notice">No restore requests.</p>
			{:else}
				<ul class="rows table">
					{#each view.restores as restore (restore.restoreId)}
						<li class="row">
							<span class="c-main">
								<span class="t-strong"
									>From {restore.backup.readyAt ? watDateTime(restore.backup.readyAt) : 'a'} backup</span
								>
								<span class="t-muted"
									>{restore.requestedBy ? personName(restore.requestedBy) : ''} · {watDateTime(
										restore.createdAt
									)}{restore.statusReason ? ` · ${restore.statusReason}` : ''}</span
								>
							</span>
							<span class="c-sum s-mono">{restore.reference}</span>
							<span class="c-status"
								><span class="s-pill" data-tone={RESTORE_STATUS[restore.status].tone}
									>{RESTORE_STATUS[restore.status].label}</span
								></span
							>
							<span class="c-act">
								{#if restore.canCancel}
									<button type="button" class="s-link" onclick={() => openCancel(restore)}
										>Cancel</button
									>
								{/if}
							</span>
						</li>
					{/each}
				</ul>
			{/if}
		</section>
	{/if}
</div>

<OrgDialog
	bind:open={downloadOpen}
	pose="backup-vault"
	title="Download backup?"
	subtitle={downloading
		? `${watDateTime(downloading.readyAt ?? downloading.createdAt)} · ${formatBytes(downloading.byteSize)}. It holds your network’s records: keep it safe.`
		: undefined}
	confirmLabel="Download"
	needsReason={false}
	busy={downloadBusy}
	error={downloadError}
	pinError={downloadPinError}
	onConfirm={confirmDownload}
/>

<OrgDialog
	bind:open={cancelOpen}
	pose="restore-request"
	title="Cancel this restore request?"
	subtitle={cancelling ? `${cancelling.reference}. Nothing will be restored.` : undefined}
	confirmLabel="Cancel request"
	cancelLabel="Keep it"
	tone="danger"
	needsReason={false}
	needsPin={false}
	busy={cancel.busy}
	error={cancel.error}
	onConfirm={confirmCancel}
/>

<style>
	.visually-hidden {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
		white-space: nowrap;
	}

	.hero {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		min-height: 200px;
		padding: 24px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 24px;
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 50% 30% / cover;
		color: #f2f4f4;
		isolation: isolate;
	}

	.hero-shade {
		position: absolute;
		inset: 0;
		z-index: -1;
		background: linear-gradient(90deg, #1a1d1e 0%, #1a1d1ee6 45%, #1a1d1e00 80%);
	}

	.hero :global(.hero-root) {
		position: absolute;
		right: 12px;
		bottom: -8px;
		z-index: -1;
		width: 120px;
		height: auto;
	}

	.hero-text {
		display: flex;
		flex-direction: column;
		gap: 8px;
		max-width: 70%;
	}

	.hero-eyebrow {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 10px;
		margin: 0;
		font-size: 15px;
		line-height: 20px;
	}

	.hero-eyebrow .s-pill[data-tone='success'] {
		background: #1d2e26;
		color: #43c48b;
	}

	.hero h1 {
		margin: 0;
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 34px;
	}

	.hero-line {
		margin: 0;
		color: #b9c0c2;
		font-size: 14px;
		line-height: 20px;
	}

	.vault-actions {
		display: flex;
		flex-wrap: wrap;
		gap: 12px;
	}

	.restore-link {
		margin-left: auto;
	}

	.table {
		margin: 0;
		padding: 0;
		overflow: clip;
		border: 1px solid var(--color-border);
		border-radius: 18px;
		background: var(--color-surface);
		list-style: none;
	}

	.rows {
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.row {
		display: grid;
		grid-template-columns: minmax(0, 1fr) auto;
		align-items: center;
		gap: 6px 16px;
		min-height: 60px;
		padding: 12px 18px;
		border-top: 1px solid var(--color-border);
		font-size: 14px;
		line-height: 18px;
	}

	.rows > .row:first-child {
		border-top: 0;
	}

	.row.head {
		display: none;
	}

	.c-main {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.c-size,
	.c-sum {
		grid-column: 1;
		color: var(--color-muted);
	}

	.c-status {
		grid-column: 2;
		grid-row: 1;
		justify-self: end;
	}

	.c-act {
		grid-column: 2;
		justify-self: end;
	}

	.t-strong {
		color: var(--color-text);
	}

	.t-muted {
		margin: 0;
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
	}

	.restores {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.restores-head {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		justify-content: space-between;
		gap: 4px 16px;
	}

	.restores-head h2 {
		margin: 0;
		font-size: 16px;
		font-weight: var(--font-weight-semibold);
		line-height: 20px;
	}

	@media (min-width: 1024px) {
		.hero {
			min-height: 230px;
			padding: 32px;
		}

		.hero :global(.hero-root) {
			right: 48px;
			width: 186px;
		}

		.hero h1 {
			font-size: 40px;
			line-height: 48px;
		}

		.row,
		.row.head {
			display: grid;
			grid-template-columns: minmax(0, 1fr) 120px 200px 120px 90px;
			gap: 16px;
			padding: 0 22px;
		}

		.row.head {
			min-height: 42px;
			color: var(--color-muted);
			font-family: var(--font-mono);
			font-size: 11px;
			letter-spacing: 0.08em;
			text-transform: uppercase;
		}

		.c-size,
		.c-sum,
		.c-status,
		.c-act {
			grid-column: auto;
			grid-row: auto;
		}

		.c-status {
			justify-self: start;
		}

		.restores .row {
			grid-template-columns: minmax(0, 1fr) 200px 120px 90px;
		}
	}
</style>
