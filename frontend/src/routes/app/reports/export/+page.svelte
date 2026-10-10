<!--
	Export report on mobile (Paper S06, with S13d's three formats): the same
	choices as the desktop dialog, then the workspace's recent reports.
-->
<script lang="ts">
	import { getContext, onDestroy, untrack } from 'svelte';
	import { page } from '$app/state';
	import { Exit } from 'effect';
	import type { ExportFile, ReportKind } from '#lib/contract/exports.js';
	import type { Currency } from '#lib/contract/ledger.js';
	import { newKey } from '#lib/client/api.js';
	import { ExportFiles, messageOf, retryFile } from '#lib/client/exports.svelte.js';
	import { cachedPage } from '#lib/client/page-cache.svelte.js';
	import { createReport, overviewPart, readOverview, readReports } from '#lib/client/reports.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { periodPresets, recreatePeriod, watToday, type Period } from '#lib/statements.js';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import ExportReportForm from '#lib/ui/exports/ExportReportForm.svelte';
	import FileList from '#lib/ui/exports/FileList.svelte';
	import ReportDownload from '#lib/ui/exports/ReportDownload.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import '#lib/ui/exports/exports.css';

	const shell = getContext<Shell>('shell');
	const today = watToday();
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);
	const asked = page.url.searchParams.get('kind');

	let kind = $state<ReportKind>(
		asked === 'transactions_csv' || asked === 'member_balances_csv' ? asked : 'office_pdf'
	);
	let currency = $state<Currency>('NGN');
	let period = $state<Period>(periodPresets(today)[1]!);
	let member = $state<{ walletId: string; name: string } | null>(null);
	let who = $state<'all' | 'one'>('all');
	let busy = $state(false);
	let error = $state<string | null>(null);
	let key = newKey();
	let downloading = $state<ExportFile | null>(null);
	let rowBusy = $state<string | null>(null);
	const files = new ExportFiles();
	onDestroy(() => files.stop());

	// Blueprint 23: the scope and currencies come from this month's figures
	// and the recent files from the list, both from the Reports page's cache
	// (kind 'reports'), then fresh. The form's own choices are never replaced.
	const thisMonth = periodPresets(today)[0]!;
	const figures = cachedPage(shell, {
		kind: 'reports',
		part: () => overviewPart(currency, thisMonth),
		load: () => readOverview(currency, thisMonth)
	});
	const scopeName = $derived(figures.data?.scope.name ?? '');
	const scopeKind = $derived<'office' | 'network'>(figures.data?.scope.kind ?? 'office');
	const currencies = $derived<readonly Currency[]>(figures.data?.currencies ?? ['NGN', 'USD']);
	const recent = cachedPage(shell, { kind: 'reports', part: () => 'files', load: readReports });
	$effect(() => {
		const list = recent.data;
		if (list) untrack(() => files.set(list.items, list.nextCursor));
	});

	// Changed choices are a new attempt (a new idempotency key); an unchanged
	// retry after a lost answer keeps the key (F-03).
	$effect(() => {
		void [kind, currency, period, member, who];
		key = newKey();
	});

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		if (!workspaceId) return;
		if (who === 'one' && !member) {
			error = 'Pick a member first.';
			return;
		}
		busy = true;
		error = null;
		const result = await createReport({ kind, currency, period, member }, workspaceId, key);
		busy = false;
		if (!result.ok) {
			error = result.message;
			return;
		}
		key = newKey();
		files.upsert(result.file);
	}

	async function retry(file: ExportFile) {
		rowBusy = file.exportId;
		const exit = await retryFile(file);
		rowBusy = null;
		if (Exit.isSuccess(exit)) files.upsert(exit.value);
		else error = messageOf(exit, 'We couldn’t retry this report.');
	}
</script>

<PageBar title="Export report" back="/app/reports" backLabel="Back to Reports" />

<form class="page" onsubmit={submit}>
	<CacheNote savedAt={recent.savedAt} online={shell.online} failed={recent.error !== null} />
	<section class="stage" aria-hidden="true">
		<div class="stage-shade"></div>
		<RootImage pose="export-mobile" class="stage-root" sizes="116px" eager />
		<p class="stage-title">{scopeName ? `${scopeName} report` : 'Report'}</p>
	</section>

	<ExportReportForm
		{scopeKind}
		{today}
		{currencies}
		bind:kind
		bind:currency
		bind:period
		bind:member
		bind:who
	/>

	{#if error}<p class="ex-error" role="alert">{error}</p>{/if}
	<button type="submit" class="ex-go" disabled={busy} aria-busy={busy}
		>{busy ? 'Starting…' : 'Create report'}</button
	>

	<section class="recent" aria-labelledby="ex-recent">
		<h2 class="ex-eyebrow" id="ex-recent">Recent reports</h2>
		<FileList
			files={files.files}
			busy={rowBusy}
			emptyTitle="No reports yet"
			emptyLine="Reports you create appear here and are kept for 7 days."
			onGet={(f) => (downloading = f)}
			onRetry={retry}
			hasMore={files.nextCursor !== null}
			loadingMore={files.loadingMore}
			onMore={() => files.loadMore('/api/reports')}
			onRecreate={(f) => {
				// Fills the form with the file's choices, scope included, to confirm.
				kind = f.kind as ReportKind;
				currency = f.currency;
				period = recreatePeriod(f.period, today);
				member =
					f.scope?.memberWalletId && f.scope.member
						? { walletId: f.scope.memberWalletId, name: f.scope.member.name ?? f.scope.member.uid }
						: null;
				who = member ? 'one' : 'all';
				window.scrollTo({ top: 0, behavior: 'smooth' });
			}}
		/>
	</section>
</form>

<ReportDownload bind:file={downloading} onError={(m) => (error = m)} />

<style>
	.page {
		display: flex;
		flex-direction: column;
		gap: 22px;
		padding: 8px 20px 40px;
		max-width: 560px;
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
		max-width: 200px;
		color: #f2f4f4;
		font-size: 20px;
		font-weight: var(--font-weight-semibold);
		line-height: 26px;
	}

	.recent {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	@media (min-width: 1024px) {
		.page {
			padding: 0 0 48px;
		}
	}
</style>
