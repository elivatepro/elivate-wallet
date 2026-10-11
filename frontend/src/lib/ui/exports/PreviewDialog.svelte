<!--
	Statement preview (Paper S09d desktop modal, S09 mobile full screen): the
	first page as an image ("Page 1 of N"), Share where the device can share
	files, and Download PDF. The file itself is fetched only on Download/Share.
-->
<script lang="ts">
	import { Dialog } from 'bits-ui';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import X from '@lucide/svelte/icons/x';
	import type { ExportFile } from '#lib/contract/exports.js';
	import { fetchFile, saveBlob } from '#lib/client/exports.svelte.js';
	import RootImage from '#lib/ui/RootImage.svelte';

	let { file = $bindable() }: { file: ExportFile | null } = $props();

	let open = $state(false);
	let busy = $state<'download' | 'share' | null>(null);
	let error = $state<string | null>(null);
	let canShare = $state(false);

	$effect(() => {
		open = file !== null;
		error = null;
		canShare =
			typeof navigator !== 'undefined' &&
			typeof navigator.canShare === 'function' &&
			navigator.canShare({ files: [new File(['x'], 'x.pdf', { type: 'application/pdf' })] });
	});

	$effect(() => {
		if (!open) file = null;
	});

	const pages = $derived(file?.pageCount ?? 1);

	async function take(mode: 'download' | 'share') {
		if (!file) return;
		busy = mode;
		error = null;
		const result = await fetchFile(file);
		busy = null;
		if (result.kind === 'expired') {
			error = 'This file has expired. Create it again.';
			return;
		}
		if (result.kind !== 'ok') {
			error = result.kind === 'error' ? result.message : 'We couldn’t get this file.';
			return;
		}
		if (mode === 'share') {
			try {
				await navigator.share({
					files: [new File([result.blob], result.name, { type: 'application/pdf' })]
				});
			} catch {
				// Closing the share sheet is not an error.
			}
			return;
		}
		saveBlob(result.blob, result.name);
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="pv-scrim" />
		<Dialog.Content class="pv-dialog" aria-describedby="pv-sub">
			{#if file}
				<header class="pv-band">
					<div class="pv-shade" aria-hidden="true"></div>
					<RootImage pose="statement-preview" class="pv-root" sizes="140px" />
					<Dialog.Close class="pv-back" aria-label="Close preview" type="button"
						><ChevronLeft size={22} strokeWidth={2} aria-hidden="true" /></Dialog.Close
					>
					<div class="pv-heading">
						<Dialog.Title class="pv-title">{file.period.title} · {file.currency}</Dialog.Title>
						<p class="pv-sub" id="pv-sub">PDF · {pages} {pages === 1 ? 'page' : 'pages'}</p>
					</div>
					<Dialog.Close class="pv-close" aria-label="Close preview" type="button"
						><X size={16} strokeWidth={2} aria-hidden="true" /></Dialog.Close
					>
				</header>
				<div class="pv-body">
					<img
						class="pv-page"
						src="/api/exports/{file.exportId}/preview"
						width="300"
						height="424"
						alt="First page of the {file.period.title} {file.currency} statement"
					/>
					<p class="pv-count">Page 1 of {pages}</p>
					<RootImage pose="statement-preview" class="pv-peek" sizes="120px" />
				</div>
				{#if error}<p class="pv-error" role="alert">{error}</p>{/if}
				<footer class="pv-actions">
					{#if canShare}
						<button
							type="button"
							class="pv-share"
							onclick={() => take('share')}
							disabled={busy !== null}>Share</button
						>
					{/if}
					<button
						type="button"
						class="pv-go"
						onclick={() => take('download')}
						disabled={busy !== null}>{busy === 'download' ? 'Downloading…' : 'Download PDF'}</button
					>
				</footer>
			{/if}
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.pv-scrim) {
		position: fixed;
		inset: 0;
		z-index: 50;
		background: #08090a9e;
	}

	:global(.pv-dialog) {
		position: fixed;
		inset: 0;
		z-index: 51;
		display: flex;
		flex-direction: column;
		background: var(--color-canvas);
		color: var(--color-text);
	}

	.pv-band {
		position: relative;
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: calc(8px + env(safe-area-inset-top)) 16px 10px 12px;
	}

	.pv-shade,
	.pv-band :global(.pv-root),
	.pv-band :global(.pv-close) {
		display: none;
	}

	:global(.pv-back) {
		display: flex;
		align-items: center;
		justify-content: center;
		width: var(--hit-min);
		height: var(--hit-min);
		border: 0;
		background: transparent;
		color: var(--color-text);
	}

	.pv-heading {
		flex: 1;
		text-align: center;
		padding-right: var(--hit-min);
	}

	:global(.pv-title) {
		font-size: 18px;
		font-weight: var(--font-weight-semibold);
		line-height: 24px;
	}

	.pv-sub {
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	.pv-body {
		position: relative;
		display: flex;
		flex: 1;
		flex-direction: column;
		align-items: center;
		gap: 14px;
		padding: 16px 24px;
		overflow: auto;
		background: color-mix(in oklab, var(--color-canvas) 85%, black);
	}

	.pv-page {
		width: min(300px, 100%);
		height: auto;
		aspect-ratio: 794 / 1123;
		border-radius: 4px;
		background: #fff;
		box-shadow: 0 12px 40px #0000004d;
	}

	.pv-count {
		padding: 4px 12px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--color-text);
		font-size: 13px;
		line-height: 18px;
	}

	.pv-body :global(.pv-peek) {
		position: absolute;
		right: 12px;
		bottom: 0;
		width: 110px;
		height: 148px;
		pointer-events: none;
	}

	.pv-error {
		padding: 10px 20px 0;
		color: var(--color-danger);
		font-size: 13px;
	}

	.pv-actions {
		display: flex;
		gap: 12px;
		padding: 16px 20px calc(16px + env(safe-area-inset-bottom));
		border-top: 1px solid var(--color-border);
		background: var(--color-canvas);
	}

	.pv-share,
	.pv-go {
		min-height: 52px;
		padding: 0 22px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.pv-share {
		border: 1px solid var(--color-border);
		background: transparent;
		color: var(--color-text);
	}

	.pv-go {
		flex: 1;
		border: 0;
		background: var(--button-primary-bg);
		color: var(--button-primary-ink);
		box-shadow: var(--auth-button-shadow);
	}

	@media (min-width: 1024px) {
		:global(.pv-dialog) {
			/* Slice 21: centred with auto margins, not translate(-50%) (blurry text). */
			inset: 0;
			width: 600px;
			height: fit-content;
			max-height: calc(100dvh - 96px);
			margin: auto;
			overflow: clip;
			border: 1px solid color-mix(in oklab, var(--color-text) 10%, transparent);
			border-radius: 24px;
			background: var(--color-surface);
		}

		.pv-band {
			height: 122px;
			padding: 0 28px;
			overflow: clip;
			background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 70% 40% / cover;
			color: #f2f4f4;
		}

		.pv-shade {
			display: block;
			position: absolute;
			inset: 0;
			background-image: linear-gradient(
				in oklab 90deg,
				oklab(21.5% -0.004 -0.003 / 95%) 0%,
				oklab(21.5% -0.004 -0.003 / 60%) 55%,
				oklab(21.5% -0.004 -0.003 / 0%) 100%
			);
		}

		.pv-band :global(.pv-root) {
			display: block;
			position: absolute;
			right: 78px;
			bottom: -26px;
			width: 110px;
			height: 148px;
		}

		.pv-band :global(.pv-back) {
			display: none;
		}

		.pv-heading {
			position: relative;
			padding: 0;
			text-align: left;
		}

		:global(.pv-title) {
			font-size: 26px;
			line-height: 32px;
			color: #fff;
		}

		.pv-sub {
			color: #d5dadb;
			font-size: 14px;
		}

		.pv-band :global(.pv-close) {
			display: flex;
			position: relative;
			align-items: center;
			justify-content: center;
			width: 38px;
			height: 38px;
			border: 0;
			border-radius: var(--radius-pill);
			background: #2c3133cc;
			color: #f2f4f4;
		}

		.pv-body {
			padding: 24px;
		}

		.pv-body :global(.pv-peek) {
			display: none;
		}

		.pv-actions {
			justify-content: flex-end;
			background: var(--color-surface);
		}

		.pv-go {
			flex: 0 0 auto;
		}
	}
</style>
