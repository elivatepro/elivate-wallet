<!--
	Files of a person or workspace (Paper S08d/S11d "Your files", S06/S10
	"Recent reports"/"Your files"): format tile, period · currency, a line,
	status (desktop) and the one action each state allows: Get (ready),
	Retry (failed), Recreate (expired). Preparing rows spin; nothing else.
-->
<script lang="ts">
	import Download from '@lucide/svelte/icons/download';
	import LoaderCircle from '@lucide/svelte/icons/loader-circle';
	import type { ExportFile } from '#lib/contract/exports.js';
	import { fileLine, fileState, type FileState } from '#lib/statements.js';

	let {
		files,
		emptyTitle = 'No files yet',
		emptyLine = 'Files you create appear here and are kept for 7 days.',
		busy = null,
		hasMore = false,
		loadingMore = false,
		onMore,
		onGet,
		onRetry,
		onRecreate
	}: {
		files: readonly ExportFile[];
		emptyTitle?: string;
		emptyLine?: string;
		/** The file whose action is running. */
		busy?: string | null;
		/** Older files exist (the list pages, newest first). */
		hasMore?: boolean;
		loadingMore?: boolean;
		onMore?: () => void;
		onGet: (file: ExportFile) => void;
		onRetry: (file: ExportFile) => void;
		onRecreate: (file: ExportFile) => void;
	} = $props();

	const STATUS: Record<FileState, string> = {
		preparing: 'Preparing…',
		ready: 'Ready',
		failed: 'Failed',
		too_large: 'Too large',
		expired: 'Expired'
	};

	/** Mobile has no status column: the line says it (Paper S06/S10). */
	const mobileLine = (file: ExportFile) => {
		const state = fileState(file);
		if (state === 'ready')
			return `Ready · ${fileLine(file).split(' · ').slice(1).join(' · ')}`.replace(/ · $/, '');
		if (state === 'failed') return 'Couldn’t finish · Tap to retry';
		if (state === 'expired') return 'Expired · Create it again';
		return fileLine(file);
	};
</script>

<div class="ex-files">
	{#each files as file (file.exportId)}
		{@const state = fileState(file)}
		<div class="ex-row" data-state={state}>
			<span class="ex-tile" data-format={file.format} aria-hidden="true"
				>{file.format.toUpperCase()}</span
			>
			<span class="ex-row-text">
				<span class="ex-row-title">{file.period.title} · {file.currency}</span>
				<span class="ex-row-line desktop-line">{fileLine(file)}</span>
				<span class="ex-row-line mobile-only">{mobileLine(file)}</span>
			</span>
			<span class="ex-row-status" data-state={state}>
				{#if state === 'preparing'}
					<LoaderCircle size={12} strokeWidth={3} class="ex-spin" aria-hidden="true" />
				{:else}
					<span class="ex-dot" aria-hidden="true"></span>
				{/if}
				{STATUS[state]}
			</span>
			<span class="ex-row-action">
				{#if state === 'ready'}
					<button
						type="button"
						class="ex-action icon-only"
						onclick={() => onGet(file)}
						disabled={busy === file.exportId}
						aria-label="Get {file.period.title} {file.currency} {file.format.toUpperCase()}"
					>
						<Download size={14} strokeWidth={2} aria-hidden="true" /><span class="ex-action-text"
							>Get</span
						>
					</button>
				{:else if state === 'failed'}
					<button
						type="button"
						class="ex-action"
						onclick={() => onRetry(file)}
						disabled={busy === file.exportId}>Retry</button
					>
				{:else if state === 'expired'}
					<button
						type="button"
						class="ex-action"
						onclick={() => onRecreate(file)}
						disabled={busy === file.exportId}>Recreate</button
					>
				{/if}
			</span>
		</div>
	{:else}
		<div class="ex-empty">
			<strong>{emptyTitle}</strong>
			<span>{emptyLine}</span>
		</div>
	{/each}
	{#if hasMore && onMore}
		<button type="button" class="more" onclick={onMore} disabled={loadingMore}
			>{loadingMore ? 'Loading…' : 'Show older files'}</button
		>
	{/if}
</div>

<style>
	.more {
		min-height: 48px;
		border: 0;
		border-top: 1px solid color-mix(in oklab, var(--color-text) 4%, transparent);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 14px;
		cursor: pointer;
	}

	@media (max-width: 1023.98px) {
		.desktop-line {
			display: none;
		}
	}
</style>
