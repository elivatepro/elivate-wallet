<!--
	Evidence field of the Blueprint 12 forms (Paper B07 "Evidence of the
	conversion", E05 "Evidence", W07 "Proof of return"): picked files, green
	once uploaded, with Remove; a dashed box adds more (PDF, JPG or PNG, up to
	five, 10 MB each). Uploading happens on submit (EntryEvidence.upload).
-->
<script lang="ts">
	import FileText from '@lucide/svelte/icons/file-text';
	import Upload from '@lucide/svelte/icons/upload';
	import { EVIDENCE_MAX_FILES, type EntryEvidence } from '#lib/client/entry-evidence.svelte.js';
	import { formatSize } from '#lib/income.js';

	let {
		evidence,
		label,
		addTitle,
		addHint = 'Required · PDF or image',
		error = null
	}: {
		evidence: EntryEvidence;
		label: string;
		addTitle: string;
		addHint?: string;
		error?: string | null;
	} = $props();

	let input: HTMLInputElement | undefined = $state();
	const id = `evidence-${Math.random().toString(36).slice(2, 8)}`;
</script>

<div class="en-field">
	<div class="en-label-row">
		<span class="en-label" id={`${id}-label`}>{label}</span>
		<span class="en-hint">Required</span>
	</div>
	{#each evidence.files as f (f.id)}
		<div class="en-file" class:uploaded={!!f.evidenceId}>
			<span class="en-file-icon" aria-hidden="true"><FileText size={20} strokeWidth={1.8} /></span>
			<span class="en-file-text">
				<span class="en-file-name">{f.file.name}</span>
				<span class="en-file-state" aria-live="polite"
					>{f.progress !== null
						? `Uploading · ${Math.round(f.progress * 100)}%`
						: `${f.evidenceId ? 'Uploaded' : 'Ready to upload'} · ${formatSize(f.file.size)}`}</span
				>
			</span>
			<button
				type="button"
				class="en-file-action"
				onclick={() => evidence.remove(f.id)}
				aria-label={`Remove ${f.file.name}`}>Remove</button
			>
		</div>
	{/each}
	{#if evidence.files.length < EVIDENCE_MAX_FILES}
		<input
			bind:this={input}
			class="visually-hidden"
			type="file"
			multiple
			accept="application/pdf,image/jpeg,image/png"
			aria-labelledby={`${id}-label`}
			onchange={(e) => {
				evidence.add(e.currentTarget.files);
				e.currentTarget.value = '';
			}}
		/>
		<button type="button" class="en-drop" onclick={() => input?.click()}>
			<Upload size={18} strokeWidth={1.8} aria-hidden="true" />
			<span class="en-drop-title">{evidence.files.length ? 'Add another file' : addTitle}</span>
			<span class="en-drop-sub">{addHint}</span>
		</button>
	{/if}
	{#if evidence.problem ?? error}<p class="en-error" role="alert">
			{evidence.problem ?? error}
		</p>{/if}
</div>
