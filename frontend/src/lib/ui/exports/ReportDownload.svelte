<!--
	Download a leadership report (owner decision Q7, Paper S14d): the file
	streams through the app; the backend asks for a fresh PIN (5-minute
	step-up), so the PIN dialog opens only when it is needed.
-->
<script lang="ts">
	import { Exit } from 'effect';
	import type { ExportFile } from '#lib/contract/exports.js';
	import { fetchFile, messageOf, saveBlob, unlockDownloads } from '#lib/client/exports.svelte.js';
	import { KIND_LABELS } from '#lib/statements.js';
	import OrgDialog from '#lib/ui/org/OrgDialog.svelte';
	import '#lib/ui/org/org.css';

	let {
		file = $bindable(),
		onError
	}: { file: ExportFile | null; onError: (message: string) => void } = $props();

	let open = $state(false);
	let busy = $state(false);
	let pinError = $state<string | null>(null);
	let pending = $state<ExportFile | null>(null);

	$effect(() => {
		if (file) {
			pending = file;
			file = null;
			void start(pending);
		}
	});

	async function start(target: ExportFile) {
		const result = await fetchFile(target);
		if (result.kind === 'ok') return saveBlob(result.blob, result.name);
		if (result.kind === 'step_up') {
			pinError = null;
			open = true;
			return;
		}
		onError(result.kind === 'expired' ? 'This file has expired. Create it again.' : result.message);
	}

	async function confirm({ pin }: { reason: string; pin: string | undefined }) {
		if (!pending) return;
		if (!pin || !/^[0-9]{4}$/.test(pin)) {
			pinError = 'Enter your 4-digit PIN.';
			return;
		}
		busy = true;
		const unlocked = await unlockDownloads(pin);
		if (Exit.isFailure(unlocked)) {
			busy = false;
			pinError = messageOf(unlocked, 'That PIN didn’t work.');
			return;
		}
		const result = await fetchFile(pending);
		busy = false;
		if (result.kind === 'ok') {
			open = false;
			saveBlob(result.blob, result.name);
		} else {
			open = false;
			onError(result.kind === 'error' ? result.message : 'We couldn’t download this report.');
		}
	}
</script>

<OrgDialog
	bind:open
	pose="export-report"
	title="Download report"
	subtitle="It holds your team’s money. Enter your PIN."
	confirmLabel={pending?.format === 'csv' ? 'Download CSV' : 'Download PDF'}
	needsReason={false}
	needsPin
	{busy}
	{pinError}
	onConfirm={confirm}
>
	{#if pending}
		<div class="file">
			<span class="ex-tile" data-format={pending.format} aria-hidden="true"
				>{pending.format.toUpperCase()}</span
			>
			<span class="ex-row-text">
				<span class="ex-row-title">{pending.period.title} · {pending.currency}</span>
				<span class="ex-row-line"
					>{KIND_LABELS[pending.kind]}{pending.pageCount ? ` · ${pending.pageCount} pages` : ''} · {pending.reference}</span
				>
			</span>
		</div>
	{/if}
</OrgDialog>

<style>
	.file {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 14px 16px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: color-mix(in oklab, var(--color-canvas) 70%, var(--color-surface));
	}
</style>
