<!--
	Export report fields (Paper S05 dialog, S06 mobile page, S13d three
	formats): who (whole scope or one member, picked from Member wallets),
	what (office report PDF, transactions CSV, member balances CSV), period
	and currency. The backend checks every choice (export_scoped_reports).
-->
<script lang="ts">
	import { Effect, Exit } from 'effect';
	import type { Currency } from '#lib/contract/ledger.js';
	import { ReportMembers, type ReportKind } from '#lib/contract/exports.js';
	import { getJson } from '#lib/client/api.js';
	import { customPeriod, periodPresets, periodTitle, type Period } from '#lib/statements.js';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';
	import PeriodPicker from './PeriodPicker.svelte';

	let {
		scopeKind,
		today,
		currencies,
		kind = $bindable(),
		currency = $bindable(),
		period = $bindable(),
		member = $bindable(),
		who = $bindable('all'),
		compact = false
	}: {
		scopeKind: 'office' | 'network';
		today: string;
		currencies: readonly Currency[];
		kind: ReportKind;
		currency: Currency;
		period: Period;
		member: { walletId: string; name: string } | null;
		who?: 'all' | 'one';
		/** Desktop dialog (Paper S05): period dropdown and currency side by side. */
		compact?: boolean;
	} = $props();

	const presets = $derived(periodPresets(today));
	let customOpen = $state(false);
	let customFrom = $state('');
	let customTo = $state('');
	const presetId = $derived(
		customOpen
			? 'custom'
			: (presets.find((p) => p.kind === period.kind && p.from === period.from && p.to === period.to)
					?.id ?? 'custom')
	);

	function choose(id: string) {
		if (id === 'custom') {
			customOpen = true;
			customFrom = period.from;
			customTo = period.to > today ? today : period.to;
			return;
		}
		customOpen = false;
		const p = presets.find((x) => x.id === id);
		if (p) period = { kind: p.kind, from: p.from, to: p.to };
	}

	function applyCustom() {
		if (customFrom && customTo && customFrom <= customTo && customFrom <= today) {
			period = customPeriod(customFrom, customTo);
		}
	}

	let q = $state('');
	let found = $state<{ walletId: string; name: string; uid: string }[]>([]);
	let searching = $state(false);
	let timer: ReturnType<typeof setTimeout> | null = null;

	$effect(() => {
		if (who === 'all') member = null;
	});

	function search() {
		if (timer) clearTimeout(timer);
		const term = q.trim();
		if (term.length < 2) {
			found = [];
			return;
		}
		timer = setTimeout(async () => {
			searching = true;
			const exit = await Effect.runPromiseExit(
				getJson(`/api/reports/members?${new URLSearchParams({ q: term })}`, ReportMembers)
			);
			searching = false;
			found = Exit.isSuccess(exit)
				? exit.value.items
						.filter((i) => i.person)
						.slice(0, 6)
						.map((i) => ({
							walletId: i.walletId,
							name: i.person?.name ?? i.person?.uid ?? '',
							uid: i.person?.uid ?? ''
						}))
				: [];
		}, 250);
	}

	const KINDS: { kind: ReportKind; title: string; sub: string }[] = [
		{
			kind: 'office_pdf',
			title: 'Office report · PDF',
			sub: 'Balances, pockets, withdrawals, members'
		},
		{
			kind: 'transactions_csv',
			title: 'Transactions · CSV',
			sub: 'Every posted record, one per row'
		},
		{
			kind: 'member_balances_csv',
			title: 'Member balances · CSV',
			sub: 'Opening, in, out, closing, reserved, per member'
		}
	];
</script>

<div class="ex-field" role="group" aria-labelledby="ex-who">
	<span class="ex-label" id="ex-who">Who</span>
	<div class="ex-segment">
		<button type="button" aria-pressed={who === 'all'} onclick={() => (who = 'all')}
			>{scopeKind === 'network' ? 'Whole network' : 'Whole office'}</button
		>
		<button type="button" aria-pressed={who === 'one'} onclick={() => (who = 'one')}
			>One member</button
		>
	</div>
	{#if who === 'one'}
		{#if member}
			<div class="picked">
				<span>{member.name}</span>
				<button type="button" class="ex-action" onclick={() => (member = null)}>Change</button>
			</div>
		{:else}
			<input
				class="ex-input"
				type="search"
				placeholder="Search by name or UID"
				aria-label="Find a member"
				bind:value={q}
				oninput={search}
			/>
			{#if found.length}
				<ul class="results">
					{#each found as person (person.walletId)}
						<li>
							<button
								type="button"
								onclick={() => (member = { walletId: person.walletId, name: person.name })}
							>
								<span>{person.name}</span><span class="uid">{person.uid}</span>
							</button>
						</li>
					{/each}
				</ul>
			{:else if q.trim().length >= 2 && !searching}
				<p class="ex-hint">No one in your scope matches.</p>
			{/if}
		{/if}
	{/if}
</div>

<fieldset class="ex-field">
	<legend class="ex-label">What</legend>
	<div class="ex-options">
		{#each KINDS as option (option.kind)}
			<label class="ex-option">
				<input type="radio" name="report-kind" value={option.kind} bind:group={kind} />
				<span
					><span class="ex-option-title">{option.title}</span><span class="ex-option-sub"
						>{option.sub}</span
					></span
				>
			</label>
		{/each}
	</div>
</fieldset>

{#if compact}
	<div class="pair">
		<div class="ex-field grow">
			<label class="ex-label" for="ex-report-period">Period</label>
			<WheelPicker
				id="ex-report-period"
				class="ex-select"
				label="Period"
				options={[
					...presets.map((p) => ({
						value: p.id,
						label: periodTitle(p),
						hint: periodTitle(p).startsWith(p.label) ? undefined : p.label
					})),
					{ value: 'custom', label: 'Custom…' }
				]}
				value={presetId}
				onchange={choose}
			/>
		</div>
		<div class="ex-field" role="group" aria-labelledby="ex-currency">
			<span class="ex-label" id="ex-currency">Currency</span>
			<div class="ex-segment">
				{#each currencies as c (c)}
					<button type="button" aria-pressed={currency === c} onclick={() => (currency = c)}
						>{c}</button
					>
				{/each}
			</div>
		</div>
	</div>
	{#if customOpen}
		<div class="ex-dates">
			<label
				>From<input
					class="ex-input"
					type="date"
					max={today}
					bind:value={customFrom}
					onchange={applyCustom}
				/></label
			>
			<label
				>To<input
					class="ex-input"
					type="date"
					min={customFrom}
					bind:value={customTo}
					onchange={applyCustom}
				/></label
			>
		</div>
	{/if}
{:else}
	<PeriodPicker {today} bind:period />

	<div class="ex-field" role="group" aria-labelledby="ex-currency">
		<span class="ex-label" id="ex-currency">Currency</span>
		<div class="ex-segment">
			{#each currencies as c (c)}
				<button type="button" aria-pressed={currency === c} onclick={() => (currency = c)}
					>{c}</button
				>
			{/each}
		</div>
	</div>
{/if}

<style>
	.pair {
		display: flex;
		gap: 16px;
	}

	.pair .grow {
		flex: 1;
	}

	.pair .ex-segment {
		min-width: 170px;
	}

	.picked {
		display: flex;
		align-items: center;
		justify-content: space-between;
		min-height: 46px;
		padding: 0 6px 0 14px;
		border: 1px solid var(--color-border);
		border-radius: 12px;
		font-size: 14px;
	}

	.results {
		display: flex;
		flex-direction: column;
		list-style: none;
		border: 1px solid var(--color-border);
		border-radius: 12px;
		overflow: clip;
	}

	.results button {
		display: flex;
		justify-content: space-between;
		width: 100%;
		min-height: 44px;
		padding: 0 14px;
		border: 0;
		border-bottom: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 14px;
		cursor: pointer;
	}

	.results li:last-child button {
		border-bottom: 0;
	}

	.uid {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 12px;
	}
</style>
