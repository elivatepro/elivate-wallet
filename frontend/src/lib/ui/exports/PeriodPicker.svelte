<!--
	Period chips (Paper S05/S08/S10): This month · last month · last quarter ·
	year so far · Custom… Custom shows two dates; a whole month, quarter or
	year keeps its name. Dates are WAT calendar days (owner decision Q1).
-->
<script lang="ts">
	import DatePicker from '#lib/ui/DatePicker.svelte';
	import { customPeriod, periodPresets, type Period } from '#lib/statements.js';

	let {
		today,
		period = $bindable(),
		label = 'Period'
	}: { today: string; period: Period; label?: string } = $props();

	const presets = $derived(periodPresets(today));
	let custom = $state(false);
	let from = $state('');
	let to = $state('');

	const selected = (p: Period) =>
		!custom && p.kind === period.kind && p.from === period.from && p.to === period.to;

	function pick(p: Period) {
		custom = false;
		period = { kind: p.kind, from: p.from, to: p.to };
	}

	function openCustom() {
		custom = true;
		from = period.from;
		to = period.to > today ? today : period.to;
		apply();
	}

	function apply() {
		if (from && to && from <= to && from <= today) period = customPeriod(from, to);
	}
</script>

<div class="ex-field" role="group" aria-labelledby="ex-period-label">
	<span class="ex-label" id="ex-period-label">{label}</span>
	<div class="ex-chips">
		{#each presets as p (p.id)}
			<button type="button" class="ex-chip" aria-pressed={selected(p)} onclick={() => pick(p)}
				>{p.label}</button
			>
		{/each}
		<button type="button" class="ex-chip" aria-pressed={custom} onclick={openCustom}>Custom…</button
		>
	</div>
	{#if custom}
		<div class="ex-dates">
			<span class="ex-date"
				><label for="period-from">From</label><DatePicker
					id="period-from"
					class="ex-input"
					label="From"
					max={today}
					bind:value={from}
					onchange={apply}
				/></span
			>
			<span class="ex-date"
				><label for="period-to">To</label><DatePicker
					id="period-to"
					class="ex-input"
					label="To"
					min={from}
					max={today}
					bind:value={to}
					onchange={apply}
				/></span
			>
		</div>
		{#if from && to && from > to}<p class="ex-error">
				The start must be on or before the end.
			</p>{/if}
		<p class="ex-hint">Dates are in WAT (Lagos time).</p>
	{/if}
</div>
