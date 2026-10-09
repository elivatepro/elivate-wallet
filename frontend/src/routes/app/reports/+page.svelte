<!--
	Reports (Blueprint 15, W-18): Paper "Statements & reports v1" S05 desktop
	page and S12 mobile. Live figures for the workspace's scope in one
	currency and WAT period: income recorded, paid out, reserved, withdrawal
	requests, memberships vs distinct people and members by income. Export
	report (S05 dialog / S06 page, three formats per S13d) makes a file;
	downloading a report needs the PIN (S14d). Currencies are never added.
-->
<script lang="ts">
	import { getContext, onDestroy } from 'svelte';
	import { goto } from '$app/navigation';
	import { Exit } from 'effect';
	import type { ExportFile, ReportKind, ReportOverview } from '#lib/contract/exports.js';
	import type { Currency } from '#lib/contract/ledger.js';
	import { newKey } from '#lib/client/api.js';
	import { ExportFiles, messageOf, retryFile } from '#lib/client/exports.svelte.js';
	import { createReport, loadOverview, loadReports } from '#lib/client/reports.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { formatMoney, hiddenMoney, isZero } from '#lib/money.js';
	import { periodPresets, watToday, type Period } from '#lib/statements.js';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import ExportReportForm from '#lib/ui/exports/ExportReportForm.svelte';
	import FileList from '#lib/ui/exports/FileList.svelte';
	import PeriodPicker from '#lib/ui/exports/PeriodPicker.svelte';
	import ReportDownload from '#lib/ui/exports/ReportDownload.svelte';
	import OrgDialog from '#lib/ui/org/OrgDialog.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import '#lib/ui/exports/exports.css';
	import '#lib/ui/org/org.css';

	const shell = getContext<Shell>('shell');
	const today = watToday();
	const workspaceId = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);

	let currency = $state<Currency>('NGN');
	let period = $state<Period>(periodPresets(today)[0]!);
	let overview = $state<ReportOverview | null>(null);
	let failed = $state<string | null>(null);
	let notice = $state<string | null>(null);
	const files = new ExportFiles();
	onDestroy(() => files.stop());

	// Export dialog (desktop S05/S13d).
	let exportOpen = $state(false);
	let exportKind = $state<ReportKind>('office_pdf');
	let exportCurrency = $state<Currency>('NGN');
	let exportPeriod = $state<Period>(periodPresets(today)[1]!);
	let exportMember = $state<{ walletId: string; name: string } | null>(null);
	let exportWho = $state<'all' | 'one'>('all');
	let exportBusy = $state(false);
	let exportError = $state<string | null>(null);
	let exportKey = newKey();
	let downloading = $state<ExportFile | null>(null);
	let rowBusy = $state<string | null>(null);

	$effect(() => {
		if (!workspaceId) return;
		const controller = new AbortController();
		const c = currency;
		const p = period;
		void loadOverview(c, p, controller.signal).then((exit) => {
			if (controller.signal.aborted) return;
			if (Exit.isSuccess(exit)) {
				overview = exit.value;
				failed = null;
			} else failed = messageOf(exit, 'We couldn’t load the report figures.');
		});
		return () => controller.abort();
	});

	$effect(() => {
		if (!workspaceId) return;
		void loadReports().then((exit) => {
			if (Exit.isSuccess(exit)) files.set(exit.value.items);
		});
	});

	const money = (amount: string) =>
		shell.hideAmounts ? hiddenMoney(currency) : formatMoney(amount, currency);
	const held = (kind: string) => overview?.held.find((h) => h.kind === kind);
	const stage = (s: string) => overview?.withdrawals.find((w) => w.stage === s);
	const income = $derived(held('income')?.amount ?? '0.00');
	const paidOut = $derived(stage('completed'));
	const requested = $derived(stage('requested'));
	const approved = $derived(stage('approved'));
	const currencies = $derived<readonly Currency[]>(overview?.currencies ?? ['NGN', 'USD']);

	function openExport(kind: ReportKind) {
		exportKind = kind;
		exportCurrency = currency;
		exportPeriod = period;
		exportMember = null;
		exportWho = 'all';
		exportError = null;
		exportKey = newKey();
		if (window.matchMedia('(min-width: 1024px)').matches) exportOpen = true;
		else void goto(`/app/reports/export?kind=${kind}`);
	}

	async function submitExport() {
		if (!workspaceId) return;
		exportBusy = true;
		exportError = null;
		const result = await createReport(
			{ kind: exportKind, currency: exportCurrency, period: exportPeriod, member: exportMember },
			workspaceId,
			exportKey
		);
		exportBusy = false;
		if (!result.ok) {
			exportError = result.message;
			return;
		}
		exportKey = newKey();
		exportOpen = false;
		files.upsert(result.file);
		notice = 'Your report is being made. It appears under Recent reports.';
	}

	async function retry(file: ExportFile) {
		rowBusy = file.exportId;
		const exit = await retryFile(file);
		rowBusy = null;
		if (Exit.isSuccess(exit)) files.upsert(exit.value);
		else notice = messageOf(exit, 'We couldn’t retry this report.');
	}

	async function recreate(file: ExportFile) {
		if (!workspaceId) return;
		rowBusy = file.exportId;
		const result = await createReport(
			{
				kind: file.kind as ReportKind,
				currency: file.currency,
				period: { kind: file.period.kind, from: file.period.from, to: file.period.to },
				member: null
			},
			workspaceId
		);
		rowBusy = null;
		if (result.ok) files.upsert(result.file);
		else notice = result.message;
	}
</script>

<PageBar title="Reports" back="/app/more" backLabel="Back to More" />

<div class="page">
	<div class="controls">
		<div class="ex-segment small" role="group" aria-label="Currency">
			{#each currencies as c (c)}
				<button type="button" aria-pressed={currency === c} onclick={() => (currency = c)}
					>{c === 'NGN' ? '₦' : '$'} {c}</button
				>
			{/each}
		</div>
		<div class="period"><PeriodPicker {today} bind:period label="Period" /></div>
		{#if overview?.canExport}
			<button
				type="button"
				class="ex-action csv desktop-only"
				onclick={() => openExport('transactions_csv')}>Export CSV</button
			>
		{/if}
	</div>

	<section class="hero">
		<div class="hero-shade" aria-hidden="true"></div>
		<RootImage pose="reports" class="hero-root" sizes="(min-width: 1024px) 178px, 140px" eager />
		<div class="hero-copy">
			<p class="hero-amount">{overview ? money(income) : '—'}</p>
			<p class="hero-sub">
				Income recorded · {overview?.period.title ?? ''} · {currency}
			</p>
		</div>
		{#if overview?.canExport}
			<button
				type="button"
				class="ex-go hero-go desktop-only"
				onclick={() => openExport('office_pdf')}>Export PDF</button
			>
		{/if}
	</section>

	{#if overview?.canExport}
		<button type="button" class="ex-go mobile-only" onclick={() => openExport('office_pdf')}
			>Export report</button
		>
	{/if}

	{#if failed}<p class="ex-error" role="alert">{failed}</p>{/if}
	{#if notice}<p class="notice" role="status">{notice}</p>{/if}

	{#if overview}
		<section class="kpis" aria-label="Totals">
			<div class="kpi">
				<span class="kpi-label">Paid out</span>
				<span class="kpi-value">{money(paidOut?.amount ?? '0.00')}</span>
				<span class="kpi-sub">{paidOut?.count ?? 0} completed</span>
			</div>
			<div class="kpi">
				<span class="kpi-label"
					>{overview.period.current ? 'Reserved now' : 'Reserved at the end'}</span
				>
				<span class="kpi-value" class:warn={!isZero(overview.reserved)}
					>{money(overview.reserved)}</span
				>
				<span class="kpi-sub"
					>{overview.reservedCount} open {overview.reservedCount === 1
						? 'request'
						: 'requests'}</span
				>
			</div>
			<div class="kpi">
				<span class="kpi-label">Withdrawal requests</span>
				<span class="kpi-value">{requested?.count ?? 0}</span>
				<span class="kpi-sub"
					>{approved?.count ?? 0} approved · {paidOut?.count ?? 0} completed</span
				>
			</div>
			<div class="kpi">
				<span class="kpi-label">Active memberships · distinct people</span>
				<span class="kpi-value">{overview.counts.activeMemberships} · {overview.counts.people}</span
				>
				<span class="kpi-sub">{overview.counts.joined} joined in this period</span>
			</div>
		</section>

		<section class="members" aria-label="By member">
			<div class="m-row m-head">
				<span>By member</span><span class="r">Income</span><span class="r desktop-only"
					>Paid out</span
				><span class="r desktop-only">Reserved</span>
			</div>
			{#each overview.members.top as m (m.member?.uid)}
				<div class="m-row">
					<span class="m-name">{m.member?.name ?? m.member?.uid}</span>
					<span class="r">{money(m.income)}</span>
					<span class="r desktop-only">{money(m.paidOut)}</span>
					<span class="r desktop-only" class:warn={!isZero(m.reserved)}>{money(m.reserved)}</span>
				</div>
			{:else}
				<div class="m-row m-empty"><span>No member money in this period.</span></div>
			{/each}
			{#if overview.members.rest.count > 0}
				<div class="m-row m-rest">
					<span
						>{overview.members.rest.count} more {overview.members.rest.count === 1
							? 'member'
							: 'members'}</span
					>
					<span class="r">{money(overview.members.rest.income)}</span>
					<span class="r desktop-only">{money(overview.members.rest.paidOut)}</span>
					<span class="r desktop-only">{money(overview.members.rest.reserved)}</span>
				</div>
			{/if}
		</section>
		{#if overview.excludedPeople > 0}
			<p class="excluded">
				{overview.excludedPeople}
				{overview.excludedPeople === 1 ? 'person' : 'people'} in this scope {overview.excludedPeople ===
				1
					? 'is'
					: 'are'}
				outside your permission and not included.
			</p>
		{/if}
	{/if}

	{#if files.files.length}
		<section class="recent" aria-labelledby="ex-recent">
			<h2 class="ex-eyebrow" id="ex-recent">Recent reports</h2>
			<FileList
				files={files.files}
				busy={rowBusy}
				onGet={(f) => (downloading = f)}
				onRetry={retry}
				onRecreate={recreate}
			/>
		</section>
	{/if}
</div>

<OrgDialog
	bind:open={exportOpen}
	pose="export-report"
	title="Export report"
	subtitle={overview?.scope.name ?? ''}
	confirmLabel="Create report"
	needsReason={false}
	needsPin={false}
	busy={exportBusy}
	error={exportError}
	validate={() => (exportWho === 'one' && exportMember === null ? 'Pick a member first.' : null)}
	onConfirm={submitExport}
>
	<ExportReportForm
		scopeKind={overview?.scope.kind ?? 'office'}
		{today}
		currencies={overview?.currencies ?? ['NGN', 'USD']}
		bind:kind={exportKind}
		bind:currency={exportCurrency}
		bind:period={exportPeriod}
		bind:member={exportMember}
		bind:who={exportWho}
		compact
	/>
</OrgDialog>

<ReportDownload bind:file={downloading} onError={(m) => (notice = m)} />

<style>
	.page {
		display: flex;
		flex-direction: column;
		gap: 20px;
		padding: 8px 20px 40px;
	}

	.desktop-only {
		display: none;
	}

	.controls {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.hero {
		/* Paper S12: the hero leads on mobile, above currency and period. */
		order: -1;
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		height: 150px;
		padding: 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 20px;
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 80% / cover;
		background-origin: border-box;
		color: #f2f4f4;
		isolation: isolate;
	}

	.hero-shade {
		position: absolute;
		inset: 0;
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(21.5% -0.004 -0.003 / 95%) 0%,
			oklab(21.5% -0.004 -0.003 / 60%) 55%,
			oklab(21.5% -0.004 -0.003 / 0%) 100%
		);
	}

	.hero :global(.hero-root) {
		position: absolute;
		right: 0;
		bottom: -10px;
		width: 140px;
		height: 156px;
	}

	.hero-copy {
		position: relative;
		max-width: 220px;
	}

	.hero-amount {
		font-size: 26px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 32px;
	}

	.hero-sub {
		color: #a9b0b3;
		font-size: 13px;
		line-height: 18px;
	}

	.notice {
		color: var(--color-muted);
		font-size: 13px;
	}

	.kpis {
		display: flex;
		flex-direction: column;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 16px;
		background: var(--color-surface);
	}

	.kpi {
		display: grid;
		grid-template-columns: 1fr auto;
		grid-template-areas: 'label value' 'sub value';
		align-items: center;
		gap: 2px 12px;
		padding: 16px 18px;
		border-bottom: 1px solid color-mix(in oklab, var(--color-text) 4%, transparent);
	}

	.kpi:last-child {
		border-bottom: 0;
	}

	.kpi-label {
		grid-area: label;
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	.kpi-value {
		grid-area: value;
		color: var(--color-text);
		font-size: 18px;
		font-weight: var(--font-weight-semibold);
		line-height: 24px;
	}

	.kpi-sub {
		grid-area: sub;
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
	}

	.warn {
		color: var(--color-warning);
	}

	.members {
		display: flex;
		flex-direction: column;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 16px;
		background: var(--color-surface);
		overflow: clip;
	}

	.m-row {
		display: grid;
		grid-template-columns: 1fr auto;
		gap: 12px;
		padding: 14px 18px;
		border-bottom: 1px solid color-mix(in oklab, var(--color-text) 4%, transparent);
		color: var(--color-text);
		font-size: 14px;
		line-height: 18px;
	}

	.m-row:last-child {
		border-bottom: 0;
	}

	.m-head {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 12px;
		letter-spacing: 0.08em;
		text-transform: uppercase;
	}

	.m-rest,
	.m-empty {
		color: var(--color-muted);
	}

	.r {
		text-align: right;
		font-variant-numeric: tabular-nums;
	}

	.excluded {
		color: var(--color-muted);
		font-size: 13px;
	}

	.recent {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	@media (min-width: 1024px) {
		.desktop-only {
			display: revert;
		}

		:global(.mobile-only) {
			display: none;
		}

		.page {
			gap: 32px;
			padding: 0 0 48px;
		}

		.controls {
			flex-direction: row;
			align-items: flex-start;
			gap: 16px;
		}

		.controls .period {
			flex: 1;
		}

		.controls .period :global(.ex-label) {
			display: none;
		}

		.ex-segment.small {
			flex-shrink: 0;
		}

		.ex-segment.small button {
			min-width: 74px;
			padding: 0 12px;
		}

		.csv {
			min-height: 40px;
			padding: 0 18px;
		}

		.hero {
			order: 0;
			height: 220px;
			padding: 34px 34px 32px;
			justify-content: space-between;
			border-radius: 24px;
		}

		.hero :global(.hero-root) {
			right: 72px;
			bottom: -24px;
			width: 178px;
			height: 240px;
		}

		.hero-copy {
			max-width: none;
		}

		.hero-amount {
			font-size: 40px;
			line-height: 48px;
		}

		.hero-sub {
			font-size: 15px;
			line-height: 20px;
		}

		.hero-go {
			position: relative;
			align-self: flex-start;
			min-height: 46px;
			padding: 0 22px;
		}

		.kpis {
			flex-direction: row;
		}

		.kpi {
			flex: 1 1 0;
			grid-template-columns: 1fr;
			grid-template-areas: 'label' 'value' 'sub';
			gap: 8px;
			padding: 22px 22px 20px;
			border-bottom: 0;
			border-right: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
		}

		.kpi:last-child {
			border-right: 0;
		}

		.kpi-value {
			font-size: 26px;
			line-height: 32px;
		}

		.m-row {
			grid-template-columns: 1fr 176px 176px 176px;
			padding: 16px 20px;
		}
	}
</style>
