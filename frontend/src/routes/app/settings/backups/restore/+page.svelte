<!--
	Request a restore (Blueprint 17, W-24; Paper V01/V02, then V03/V04 "Restore
	request sent"): pick a ready backup and say why. President Team and World
	Team (request_restore). Only Elivate checks the archive, reviews the
	differences and restores (owner answer Q1); the requester can cancel until
	restoring starts. One open request per network.
-->
<script lang="ts">
	import '#lib/ui/settings/settings.css';
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import { RestoreResult, VaultView, type Restore } from '#lib/contract/settings.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { personName } from '#lib/org.js';
	import { RESTORE_STATUS, formatBytes, shortChecksum, watDateTime } from '#lib/settings.js';
	import { Schema } from 'effect';
	import RootImage from '#lib/ui/RootImage.svelte';

	const shell = getContext<Shell>('shell');
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);

	let view = $state<VaultView | null>(null);
	let loadError = $state<string | null>(null);
	let picked = $state<string | null>(null);
	let reason = $state('');
	let reasonError = $state<string | null>(null);
	let sent = $state<Restore | null>(null);
	let started = false;

	async function load() {
		const result = await loadView('/api/backups', VaultView);
		if (result.ok) {
			view = result.value;
			const wanted = page.url.searchParams.get('backup');
			const ready = result.value.backups.filter((b) => b.status === 'ready');
			picked = ready.find((b) => b.backupId === wanted)?.backupId ?? ready[0]?.backupId ?? null;
			loadError = null;
		} else loadError = result.text;
	}

	$effect(() => {
		if (shell.state.kind === 'ready' && !started) {
			started = true;
			void load();
		}
	});

	const ready = $derived(view?.backups.filter((b) => b.status === 'ready') ?? []);
	const open = $derived(
		view?.restores.find((r) =>
			['requested', 'validating', 'in_review', 'restoring'].includes(r.status)
		) ?? null
	);

	const send = new OrgCommand();

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		const trimmed = reason.trim();
		if (trimmed.length < 10 || trimmed.length > 500) {
			reasonError = 'Say why in 10 to 500 characters.';
			return;
		}
		reasonError = null;
		if (!picked || !workspaceId) return;
		const result = await send.send(
			'/api/restores',
			'POST',
			{ backupId: picked, reason: trimmed },
			workspaceId
		);
		if (!result) return;
		try {
			sent = Schema.decodeUnknownSync(RestoreResult)(result).restore;
		} catch {
			await load();
		}
	}
</script>

<svelte:head><title>Request a restore · Elivate Wallet</title></svelte:head>

<div class="s-page">
	<section class="hero" aria-labelledby="restore-title">
		<div class="hero-shade" aria-hidden="true"></div>
		<RootImage
			pose={sent ? 'restore-sent' : 'restore-request'}
			class="hero-root"
			sizes="(min-width: 1024px) 182px, 120px"
			eager
		/>
		<div class="hero-text">
			<h1 id="restore-title">{sent ? 'Restore request sent' : 'Request a restore'}</h1>
			<p class="hero-line">
				{sent
					? 'Elivate will check the archive and review the diff. We’ll email you when it’s done.'
					: 'Pick a backup and say why. Elivate reviews it before anything changes.'}
			</p>
		</div>
	</section>

	{#if loadError}
		<p class="s-notice bad" role="alert">{loadError}</p>
	{:else if !view}
		<p class="s-notice" aria-busy="true">Loading…</p>
	{:else if sent}
		<section class="summary" aria-labelledby="summary-title">
			<div class="summary-head">
				<h2 id="summary-title">Restore request</h2>
				<span class="s-pill" data-tone={RESTORE_STATUS[sent.status].tone}
					>{RESTORE_STATUS[sent.status].label}</span
				>
			</div>
			<dl class="facts">
				<div class="fact">
					<dt>Reference</dt>
					<dd class="s-mono">{sent.reference}</dd>
				</div>
				<div class="fact">
					<dt>Backup</dt>
					<dd>
						{sent.backup.readyAt ? watDateTime(sent.backup.readyAt) : ''} · {formatBytes(
							sent.backup.byteSize
						)}
					</dd>
				</div>
				<div class="fact">
					<dt>Checksum</dt>
					<dd class="s-mono">{shortChecksum(sent.backup.sha256)}</dd>
				</div>
				<div class="fact">
					<dt>Requested by</dt>
					<dd>
						{sent.requestedBy ? personName(sent.requestedBy) : ''} · {watDateTime(sent.createdAt)}
					</dd>
				</div>
				<div class="fact">
					<dt>Reason</dt>
					<dd>{sent.reason}</dd>
				</div>
			</dl>
		</section>
		<div class="s-actions start">
			<a class="s-primary" href="/app/settings/backups">Back to backup vault</a>
		</div>
	{:else if !view.canRequestRestore}
		<p class="s-notice" role="status">
			Only the President Team and World Team can ask for a restore.
		</p>
	{:else if open}
		<p class="s-notice" role="status">
			{open.reference} is already open ({RESTORE_STATUS[open.status].label.toLowerCase()}). One
			restore request at a time.
		</p>
		<div class="s-actions start">
			<a class="s-ghost" href="/app/settings/backups">Back to backup vault</a>
		</div>
	{:else if ready.length === 0}
		<p class="s-notice" role="status">There’s no backup to restore from yet.</p>
		<div class="s-actions start">
			<a class="s-ghost" href="/app/settings/backups">Back to backup vault</a>
		</div>
	{:else}
		<form class="s-form request" onsubmit={submit} novalidate>
			<fieldset class="s-section">
				<legend class="s-section-label">Backup to restore from</legend>
				<div class="picks">
					{#each ready as backup (backup.backupId)}
						<label class="pick">
							<input type="radio" name="backup" value={backup.backupId} bind:group={picked} />
							<span class="radio" aria-hidden="true"></span>
							<span class="pick-main">
								<span class="pick-title">{watDateTime(backup.readyAt ?? backup.createdAt)}</span>
								<span class="pick-meta"
									>{formatBytes(backup.byteSize)} · encrypted · started by {backup.startedBy
										? personName(backup.startedBy)
										: 'a President'}</span
								>
							</span>
							<span class="pick-sum s-mono">{shortChecksum(backup.sha256)}</span>
							<span class="s-pill" data-tone="success">Complete</span>
						</label>
					{/each}
				</div>
			</fieldset>
			<div class="s-field">
				<label class="s-field-head" for="restore-reason">Reason</label>
				<textarea
					id="restore-reason"
					class="s-input"
					maxlength="500"
					bind:value={reason}
					aria-invalid={reasonError ? 'true' : undefined}
					aria-describedby={reasonError ? 'restore-reason-error' : undefined}></textarea>
				{#if reasonError}<p class="s-error" id="restore-reason-error">{reasonError}</p>{/if}
			</div>
			{#if send.error}<p class="s-notice bad" role="alert">{send.error}</p>{/if}
			<div class="s-actions start">
				<button type="submit" class="s-primary" disabled={send.busy || !picked || !shell.canAct}
					>Send request</button
				>
				<a class="s-ghost" href="/app/settings/backups">Cancel</a>
			</div>
		</form>
	{/if}
</div>

<style>
	.hero {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		min-height: 180px;
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
		max-width: 72%;
	}

	.hero h1 {
		margin: 0;
		font-size: 28px;
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.02em;
		line-height: 34px;
	}

	.hero-line {
		margin: 0;
		color: #d5dadb;
		font-size: 14px;
		line-height: 20px;
	}

	.request,
	.summary {
		max-width: 720px;
	}

	.picks {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.pick {
		position: relative;
		display: grid;
		grid-template-columns: 24px minmax(0, 1fr) auto;
		align-items: center;
		gap: 4px 14px;
		min-height: 66px;
		padding: 12px 16px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		cursor: pointer;
	}

	.pick input {
		position: absolute;
		inset: 0;
		z-index: 1;
		width: 100%;
		height: 100%;
		margin: 0;
		opacity: 0;
		cursor: pointer;
	}

	.pick:has(input:checked) {
		border-color: color-mix(in srgb, var(--color-text) 40%, transparent);
		background: var(--color-raised);
	}

	.pick:has(input:focus-visible) {
		outline: 2px solid var(--focus-ring);
		outline-offset: 2px;
	}

	.radio {
		width: 20px;
		height: 20px;
		border: 2px solid var(--color-muted);
		border-radius: 999px;
	}

	.pick:has(input:checked) .radio {
		border-color: var(--color-accent);
		background: radial-gradient(var(--color-accent) 0 45%, transparent 50%);
	}

	.pick-main {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.pick-title {
		color: var(--color-text);
		font-size: 14px;
		line-height: 18px;
	}

	.pick-meta {
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
	}

	.pick-sum {
		display: none;
		color: var(--color-muted);
	}

	.summary {
		overflow: clip;
		border: 1px solid var(--color-border);
		border-radius: 18px;
		background: var(--color-surface);
	}

	.summary-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 18px 24px;
		border-bottom: 1px solid var(--color-border);
	}

	.summary-head h2 {
		margin: 0;
		font-size: 16px;
		font-weight: var(--font-weight-semibold);
	}

	.facts {
		margin: 0;
	}

	.fact {
		display: flex;
		justify-content: space-between;
		gap: 16px;
		padding: 14px 24px;
		border-top: 1px solid var(--color-border);
		font-size: 14px;
		line-height: 20px;
	}

	.fact:first-child {
		border-top: 0;
	}

	.fact dt {
		color: var(--color-muted);
	}

	.fact dd {
		margin: 0;
		color: var(--color-text);
		text-align: right;
		overflow-wrap: anywhere;
	}

	@media (min-width: 1024px) {
		.hero {
			min-height: 220px;
			padding: 32px;
		}

		.hero h1 {
			font-size: 40px;
			line-height: 48px;
		}

		.hero :global(.hero-root) {
			right: 48px;
			width: 182px;
		}

		.pick {
			grid-template-columns: 24px minmax(0, 1fr) auto auto;
		}

		.pick-sum {
			display: inline;
		}
	}
</style>
