<!--
	Period chips (Paper S05/S08/S10): This month · last month · last quarter ·
	year so far · Custom… Custom shows two dates; a whole month, quarter or
	year keeps its name. Dates are WAT calendar days (owner decision Q1).
-->
<script lang="ts">
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
			<label
				>From<input
					class="ex-input"
					type="date"
					max={today}
					bind:value={from}
					onchange={apply}
				/></label
			>
			<label
				>To<input class="ex-input" type="date" min={from} bind:value={to} onchange={apply} /></label
			>
		</div>
		{#if from && to && from > to}<p class="ex-error">
				The start must be on or before the end.
			</p>{/if}
		<p class="ex-hint">Dates are in WAT (Lagos time).</p>
	{/if}
</div>
