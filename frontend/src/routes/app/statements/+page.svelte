<!--
	Statements (Blueprint 15, W-18): Paper "Statements & reports v1" S08d/S08
	(builder and files), S10d/S10 (first visit, two networks), S11d (every file
	state), S09 (preview). One network and one currency per statement; the
	network choice shows only when the person has more than one. Periods are
	WAT. Files are made by a background job and kept 7 days.
-->
<script lang="ts">
	import { onDestroy } from 'svelte';
	import { Effect, Exit } from 'effect';
	import { ExportFile, StatementsView, type StatementNetwork } from '#lib/contract/exports.js';
	import type { Currency } from '#lib/contract/ledger.js';
	import { getJson, newKey, sendAccountCommand } from '#lib/client/api.js';
	import {
		ExportFiles,
		fetchFile,
		messageOf,
		retryFile,
		saveBlob
	} from '#lib/client/exports.svelte.js';
	import { periodPresets, recreatePeriod, watToday, type Period } from '#lib/statements.js';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import FileList from '#lib/ui/exports/FileList.svelte';
	import PeriodPicker from '#lib/ui/exports/PeriodPicker.svelte';
	import PreviewDialog from '#lib/ui/exports/PreviewDialog.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import '#lib/ui/exports/exports.css';

	let view = $state<StatementsView | null>(null);
	let failed = $state<string | null>(null);
	let tenantId = $state<string | null>(null);
	let currency = $state<Currency>('NGN');
	let period = $state<Period>(periodPresets(watToday())[1]!);
	let format = $state<'pdf' | 'csv'>('pdf');
	let busy = $state(false);
	let rowBusy = $state<string | null>(null);
	let formError = $state<string | null>(null);
	let previewing = $state<ExportFile | null>(null);
	/** The idempotency key of the current attempt; kept until it succeeds (F-03). */
	let attemptKey: string | null = null;
	let waitingFor: string | null = null;

	const files = new ExportFiles((file) => {
		// A PDF made while the person waited opens its preview (Paper S09d).
		if (file.exportId === waitingFor && file.kind === 'statement_pdf' && file.hasPreview)
			previewing = file;
		waitingFor = null;
	});
	onDestroy(() => files.stop());

	async function load() {
		failed = null;
		const exit = await Effect.runPromiseExit(getJson('/api/statements', StatementsView));
		if (Exit.isFailure(exit)) {
			failed = messageOf(exit, 'We couldn’t load your statements.');
			return;
		}
		view = exit.value;
		files.set(exit.value.files.items, exit.value.files.nextCursor);
		const first = exit.value.options.networks[0];
		if (first && !tenantId) {
			tenantId = first.tenantId;
			currency = first.currencies[0] ?? 'NGN';
		}
		period = periodPresets(exit.value.options.today)[1]!;
	}
	void load();

	const networks = $derived<readonly StatementNetwork[]>(view?.options.networks ?? []);
	const network = $derived(networks.find((n) => n.tenantId === tenantId) ?? networks[0] ?? null);
	const currencies = $derived<readonly Currency[]>(network?.currencies ?? ['NGN', 'USD']);
	const latest = $derived(files.files[0] ?? null);
	const big = $derived(latest?.status === 'too_large');

	$effect(() => {
		if (network && !network.currencies.includes(currency))
			currency = network.currencies[0] ?? 'NGN';
	});

	async function create(again?: ExportFile) {
		if (!network) return;
		busy = true;
		formError = null;
		attemptKey ??= newKey();
		const redo = again ? recreatePeriod(again.period, view?.options.today ?? watToday()) : null;
		const body =
			again && redo
				? {
						tenantId: again.tenantId,
						currency: again.currency,
						periodKind: redo.kind,
						from: redo.from,
						to: redo.to,
						format: again.format,
						idempotencyKey: newKey()
					}
				: {
						tenantId: network.tenantId,
						currency,
						periodKind: period.kind,
						from: period.from,
						to: period.to,
						format,
						idempotencyKey: attemptKey
					};
		const exit = await Effect.runPromiseExit(
			sendAccountCommand('/api/statements', 'POST', body, ExportFile)
		);
		busy = false;
		if (Exit.isFailure(exit)) {
			formError = messageOf(exit, 'We couldn’t start your statement. Try again.');
			return;
		}
		if (!again) attemptKey = null;
		waitingFor = exit.value.exportId;
		files.upsert(exit.value);
	}

	async function get(file: ExportFile) {
		if (file.kind === 'statement_pdf' && file.hasPreview) {
			previewing = file;
			return;
		}
		rowBusy = file.exportId;
		const result = await fetchFile(file);
		rowBusy = null;
		if (result.kind === 'ok') saveBlob(result.blob, result.name);
		else
			formError =
				result.kind === 'error' ? result.message : 'This file has expired. Create it again.';
	}

	async function retry(file: ExportFile) {
		rowBusy = file.exportId;
		const exit = await retryFile(file);
		rowBusy = null;
		if (Exit.isSuccess(exit)) files.upsert(exit.value);
		else formError = messageOf(exit, 'We couldn’t retry this file.');
	}

	// Choosing again starts a new attempt (a new idempotency key).
	$effect(() => {
		void [tenantId, currency, period, format];
		attemptKey = null;
	});
</script>

<PageBar title="Statements" back="/app/more" backLabel="Back to More" />

{#if failed}
	<section class="ex-problem" role="alert">
		<RootImage pose="load-error" sizes="140px" class="ex-problem-root" />
		<p>{failed}</p>
		<button type="button" class="ex-action" onclick={load}>Try again</button>
	</section>
{:else if !view}
	<div class="ex-skeleton" aria-busy="true" aria-label="Loading statements"></div>
{:else if networks.length === 0}
	<section class="ex-problem">
		<RootImage pose="statements" sizes="160px" class="ex-problem-root" />
		<h1 class="ex-title">No statements yet</h1>
		<p>Statements cover your own wallet. You don’t hold money in any network yet.</p>
	</section>
{:else}
	<div class="layout">
		<section class="stage" class:big aria-hidden="true">
			<div class="stage-shade"></div>
			<RootImage
				pose={big ? 'statements-big' : 'statements'}
				class="stage-root"
				sizes="(min-width: 1024px) 168px, 116px"
				eager
			/>
			<p class="stage-title">{big ? 'That’s a big one' : 'Your money, on paper'}</p>
		</section>

		<form class="builder ex-card" onsubmit={(e) => (e.preventDefault(), void create())}>
			<h1 class="ex-title desktop-only">Create a statement</h1>

			{#if networks.length > 1}
				<div class="ex-field">
					<label class="ex-label" for="ex-network">Network</label>
					<select id="ex-network" class="ex-select" bind:value={tenantId}>
						{#each networks as n (n.tenantId)}<option value={n.tenantId}>{n.name}</option>{/each}
					</select>
					<p class="ex-hint desktop-only">One network and one currency per statement.</p>
				</div>
			{/if}

			<div class="ex-field" role="group" aria-labelledby="ex-currency">
				<span class="ex-label desktop-only" id="ex-currency">Currency</span>
				<div class="ex-segment">
					{#each currencies as c (c)}
						<button type="button" aria-pressed={currency === c} onclick={() => (currency = c)}
							>{c === 'NGN' ? '₦' : '$'} {c}</button
						>
					{/each}
				</div>
			</div>

			<PeriodPicker today={view.options.today} bind:period />

			<fieldset class="ex-field">
				<legend class="ex-label">Format</legend>
				<div class="ex-options">
					<label class="ex-option">
						<input type="radio" name="format" value="pdf" bind:group={format} />
						<span
							><span class="ex-option-title">PDF statement</span><span class="ex-option-sub"
								>With balances</span
							></span
						>
					</label>
					<label class="ex-option">
						<input type="radio" name="format" value="csv" bind:group={format} />
						<span
							><span class="ex-option-title">CSV of transactions</span><span class="ex-option-sub"
								>Transactions only</span
							></span
						>
					</label>
				</div>
			</fieldset>

			{#if formError}<p class="ex-error" role="alert">{formError}</p>{/if}
			<button type="submit" class="ex-go" disabled={busy} aria-busy={busy}
				>{busy ? 'Starting…' : format === 'pdf' ? 'Create PDF statement' : 'Create CSV'}</button
			>
		</form>

		<section class="files" aria-labelledby="ex-files">
			<h2 class="ex-files-head desktop-only" id="ex-files">Your files</h2>
			<h2 class="ex-eyebrow mobile-only">Your files</h2>
			<FileList
				files={files.files}
				busy={rowBusy}
				hasMore={files.nextCursor !== null}
				loadingMore={files.loadingMore}
				onMore={() => files.loadMore('/api/statements')}
				onGet={get}
				onRetry={retry}
				onRecreate={(f) => create(f)}
			/>
		</section>
	</div>
{/if}

<PreviewDialog bind:file={previewing} />

<style>
	.layout {
		display: flex;
		flex-direction: column;
		gap: 22px;
		padding: 8px 20px 40px;
	}

	.desktop-only {
		display: none;
	}

	.stage {
		position: relative;
		display: flex;
		align-items: flex-end;
		height: 150px;
		padding: 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 20px;
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 60% 30% / cover;
		background-origin: border-box;
		isolation: isolate;
	}

	.stage-shade {
		position: absolute;
		inset: 0;
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(21.5% -0.004 -0.003 / 92%) 0%,
			oklab(21.5% -0.004 -0.003 / 50%) 55%,
			oklab(21.5% -0.004 -0.003 / 0%) 100%
		);
	}

	.stage :global(.stage-root) {
		position: absolute;
		right: 14px;
		bottom: -8px;
		width: 116px;
		height: 156px;
	}

	.stage-title {
		position: relative;
		max-width: 210px;
		color: #f2f4f4;
		font-size: 20px;
		font-weight: var(--font-weight-semibold);
		line-height: 26px;
	}

	.files {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.ex-problem {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 12px;
		padding: 48px 24px;
		color: var(--color-muted);
		text-align: center;
	}

	.ex-problem :global(.ex-problem-root) {
		width: 140px;
		height: 188px;
	}

	.ex-skeleton {
		height: 420px;
		margin: 20px;
		border-radius: 20px;
		background: var(--color-surface);
	}

	@media (min-width: 1024px) {
		.desktop-only {
			display: block;
		}

		:global(.mobile-only) {
			display: none;
		}

		.layout {
			display: grid;
			grid-template-columns: 520px minmax(0, 1fr);
			grid-template-areas: 'builder files' 'builder stage';
			grid-template-rows: auto 1fr;
			align-items: start;
			gap: 16px 24px;
			padding: 0 0 48px;
		}

		.builder {
			grid-area: builder;
			gap: 24px;
			padding: 28px;
			border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
			border-radius: 20px;
			background: var(--color-surface);
		}

		.files {
			grid-area: files;
			padding-top: 4px;
		}

		.stage {
			grid-area: stage;
			min-height: 237px;
			height: auto;
			padding: 28px;
			border-radius: 24px;
		}

		.stage :global(.stage-root) {
			right: 56px;
			bottom: -12px;
			width: 168px;
			height: 226px;
		}

		.stage-title {
			max-width: 320px;
			font-size: 24px;
			line-height: 30px;
		}
	}
</style>
