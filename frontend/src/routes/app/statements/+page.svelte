<!--
	Statements (Blueprint 15, W-18): Paper "Statements & reports v1" S08d/S08
	(builder and files), S10d/S10 (first visit, two networks), S11d (every file
	state), S09 (preview). One network and one currency per statement; the
	network choice shows only when the person has more than one. Periods are
	WAT. Files are made by a background job and kept 7 days.
-->
<script lang="ts">
	import { enterMovesOn } from '#lib/ui/enter-moves-on.js';
	import { getContext, onDestroy, untrack } from 'svelte';
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
	import { cachedPage } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { periodPresets, recreatePeriod, watToday, type Period } from '#lib/statements.js';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import FileList from '#lib/ui/exports/FileList.svelte';
	import PeriodPicker from '#lib/ui/exports/PeriodPicker.svelte';
	import PreviewDialog from '#lib/ui/exports/PreviewDialog.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';
	import '#lib/ui/exports/exports.css';

	const shell = getContext<Shell>('shell');
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

	// Blueprint 23: the options and the first page of files open from cache,
	// then refresh. Files carry no download links (downloads go through the
	// app server by export id), so the whole view is kept.
	const page = cachedPage(shell, {
		kind: 'statements',
		load: async () => {
			const exit = await Effect.runPromiseExit(getJson('/api/statements', StatementsView));
			return Exit.isSuccess(exit)
				? { ok: true, value: exit.value }
				: { ok: false, text: messageOf(exit, 'We couldn’t load your statements.'), status: null };
		}
	});
	const view = $derived(page.data);
	const failed = $derived(page.data ? null : page.error);
	const load = () => page.reload();
	/** The default period last chosen for the person; a period they picked stays. */
	let seeded: Period | null = null;
	const samePeriod = (a: Period, b: Period) =>
		a.kind === b.kind && a.from === b.from && a.to === b.to;

	$effect(() => {
		const data = page.data;
		if (!data) return;
		untrack(() => {
			files.set(data.files.items, data.files.nextCursor);
			const first = data.options.networks[0];
			if (first && !tenantId) {
				tenantId = first.tenantId;
				currency = first.currencies[0] ?? 'NGN';
			}
			if (!seeded || samePeriod(period, seeded)) {
				period = periodPresets(data.options.today)[1]!;
				seeded = period;
			}
		});
	});

	const networks = $derived<readonly StatementNetwork[]>(view?.options.networks ?? []);
	const network = $derived(networks.find((n) => n.tenantId === tenantId) ?? networks[0] ?? null);
	const currencies = $derived<readonly Currency[]>(network?.currencies ?? ['NGN', 'USD']);

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

<CacheNote savedAt={page.savedAt} online={shell.online} failed={page.error !== null} />

{#if failed}
	<section class="ex-problem" role="alert">
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
	<!-- Blueprint 46: no Root stage beside money; the builder and files take the space. -->
	<div class="layout">
		<form
			class="builder ex-card"
			onsubmit={(e) => (e.preventDefault(), void create())}
			{@attach enterMovesOn}
		>
			<h1 class="ex-title desktop-only">Create a statement</h1>

			{#if networks.length > 1}
				<div class="ex-field">
					<label class="ex-label" for="ex-network">Network</label>
					<WheelPicker
						id="ex-network"
						class="ex-select"
						label="Network"
						options={networks.map((n) => ({ value: n.tenantId, label: n.name }))}
						bind:value={tenantId}
					/>
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
			grid-template-areas: 'builder files';
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
	}
</style>
