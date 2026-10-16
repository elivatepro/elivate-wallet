<!--
	Slice 32 (owner 2026-10-11, Paper "Date picker v8" DP01/DP02): the app's one
	date field. The field reads "2 Oct 2026"; it opens a calendar anchored under
	it on a desktop with a mouse (DP01), and a bottom sheet on phones and touch
	screens (DP02). Choosing a day closes it.
	- Before it hydrates, a native <input type="date"> with the same id, name,
	  min and max (the member app itself renders only with JS).
	- Keyboard (WAI-ARIA date picker dialog): arrows by day and week, Home/End to
	  the week's ends, Page Up/Down by month (with Shift by year), Enter/Space
	  choose, Escape closes (never a Bits dialog underneath). The month title
	  switches to a month-and-year view for long jumps.
	- Days outside min/max can't be chosen; Today / Yesterday where allowed;
	  Clear for optional fields.
	- Blueprint 43: the phone sheet closes with a drag down (as Escape does).
-->
<script lang="ts" module>
	let hydrated = false;
</script>

<script lang="ts">
	import { onMount, tick } from 'svelte';
	import CalendarIcon from '@lucide/svelte/icons/calendar';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import {
		addDays,
		addMonths,
		clamp,
		compare,
		daysIn,
		fieldLabel,
		keyMove,
		monthGrid,
		monthName,
		parseIso,
		shortLabel,
		shortMonth,
		spokenLabel,
		todayLocal,
		toIso,
		within,
		type Day
	} from './date-picker.js';
	import { sheetDrag } from './sheet-drag.js';

	let {
		value = $bindable(''),
		id,
		name,
		label,
		min,
		max,
		placeholder = 'Choose a date',
		clearable = false,
		class: className = '',
		invalid = false,
		describedby,
		disabled = false,
		today: todayIso,
		onchange
	}: {
		/** `YYYY-MM-DD`, or '' when empty. */
		value?: string;
		/** The field's id: a page's `<label for>` names it. */
		id: string;
		name?: string;
		/** What the date is ("Date received"): the sheet's title. */
		label: string;
		min?: string | undefined;
		max?: string | undefined;
		placeholder?: string;
		/** An optional date: shows Clear. */
		clearable?: boolean;
		/** The page's field class (o-input, mm-input…) for the box. */
		class?: string;
		invalid?: boolean;
		describedby?: string | undefined;
		disabled?: boolean;
		/**
		 * The day "Today" means (`YYYY-MM-DD`), when it isn't the device's: report
		 * and statement periods use WAT (Lagos).
		 */
		today?: string | undefined;
		onchange?: (value: string) => void;
	} = $props();

	const key = $props.id();
	let enhanced = $state(hydrated);
	let open = $state(false);
	let mode = $state<'pop' | 'sheet'>('pop');
	let view = $state<'days' | 'months'>('days');
	/** The day with keyboard focus (also decides the month shown). */
	let focusDay = $state<Day>(todayLocal());
	let place = $state({ left: 0, top: 0, up: false });

	let trigger: HTMLButtonElement | undefined = $state();
	let pop: HTMLDivElement | undefined = $state();
	let sheet: HTMLDialogElement | undefined = $state();
	let grid: HTMLDivElement | undefined = $state();

	const minDay = $derived(parseIso(min));
	const maxDay = $derived(parseIso(max));
	const chosen = $derived(parseIso(value));
	/** Refreshed on every open (a page left open overnight). */
	let deviceToday = $state<Day>(todayLocal());
	const today = $derived(parseIso(todayIso) ?? deviceToday);
	const yesterday = $derived(addDays(today, -1));
	const weeks = $derived(monthGrid(focusDay.y, focusDay.m));
	const canPrev = $derived(
		!minDay || compare(addMonths({ ...focusDay, d: 1 }, 0), { ...minDay, d: 1 }) > 0
	);
	const canNext = $derived(!maxDay || compare({ ...focusDay, d: 1 }, { ...maxDay, d: 1 }) < 0);
	const same = (a: Day | null, b: Day | null) => !!a && !!b && compare(a, b) === 0;

	onMount(() => {
		hydrated = true;
		enhanced = true;
		return () => detach();
	});

	async function show() {
		if (disabled || open) return;
		deviceToday = todayLocal();
		mode = matchMedia('(min-width: 1024px) and (pointer: fine)').matches ? 'pop' : 'sheet';
		view = 'days';
		focusDay = clamp(chosen ?? today, minDay, maxDay);
		if (mode === 'pop') measure();
		open = true;
		await tick();
		if (mode === 'pop') {
			try {
				pop?.showPopover();
			} catch {
				// No Popover API: it still shows, fixed under the field.
			}
			document.addEventListener('pointerdown', outside, true);
			window.addEventListener('resize', measure);
			window.addEventListener('scroll', onPageScroll, true);
		} else {
			sheet?.showModal();
		}
		focusGrid();
	}

	function close(refocus = true) {
		if (!open) return;
		detach();
		try {
			pop?.hidePopover();
		} catch {
			// not shown as a popover
		}
		sheet?.close();
		open = false;
		if (refocus) trigger?.focus();
	}

	function detach() {
		document.removeEventListener('pointerdown', outside, true);
		window.removeEventListener('resize', measure);
		window.removeEventListener('scroll', onPageScroll, true);
	}

	function choose(day: Day | null) {
		if (day && !within(day, minDay, maxDay)) return;
		const next = day ? toIso(day) : '';
		if (next !== value) {
			value = next;
			onchange?.(next);
		}
		close();
	}

	// ── Placement (desktop) ──
	const GAP = 6;
	const WIDTH = 324;
	const HEIGHT = 400;
	function measure() {
		if (!trigger) return;
		const r = trigger.getBoundingClientRect();
		const below = window.innerHeight - r.bottom - GAP - 8;
		const up = below < HEIGHT && r.top - GAP - 8 > below;
		const left = Math.min(Math.max(8, r.left), window.innerWidth - WIDTH - 8);
		place = { left, top: up ? r.top - GAP : r.bottom + GAP, up };
	}

	function onPageScroll(event: Event) {
		if (pop && event.target instanceof Node && pop.contains(event.target)) return;
		measure();
	}

	function outside(event: PointerEvent) {
		const target = event.target as Node;
		if (pop?.contains(target) || trigger?.contains(target)) return;
		close(false);
	}

	// ── Keyboard ──
	async function focusGrid() {
		await tick();
		const root = mode === 'pop' ? pop : sheet;
		const target =
			view === 'days'
				? root?.querySelector<HTMLElement>('[data-focus="true"]')
				: root?.querySelector<HTMLElement>('[data-month-focus="true"]');
		target?.focus();
	}

	function move(to: Day) {
		focusDay = clamp(to, minDay, maxDay);
		void focusGrid();
	}

	function gridKey(event: KeyboardEvent) {
		const to = keyMove(event.key, focusDay, event.shiftKey);
		if (to) {
			event.preventDefault();
			return move(to);
		}
		if (event.key === 'Enter' || event.key === ' ') {
			event.preventDefault();
			choose(focusDay);
		}
	}

	function panelKey(event: KeyboardEvent) {
		if (event.key !== 'Escape') return;
		// Ours alone: a Bits UI dialog underneath must stay open.
		event.preventDefault();
		event.stopPropagation();
		if (view === 'months') {
			view = 'days';
			return void focusGrid();
		}
		close();
	}

	function shiftMonth(n: number) {
		focusDay = clamp(addMonths(focusDay, n), minDay, maxDay);
	}

	// ── Month and year view ──
	function monthAllowed(y: number, m: number) {
		const first = { y, m, d: 1 };
		const last = { y, m, d: daysIn(y, m) };
		return (!maxDay || compare(first, maxDay) <= 0) && (!minDay || compare(last, minDay) >= 0);
	}

	function pickMonth(y: number, m: number) {
		focusDay = clamp({ y, m, d: Math.min(focusDay.d, 28) }, minDay, maxDay);
		view = 'days';
		void focusGrid();
	}

	function monthsKey(event: KeyboardEvent) {
		const step: Record<string, number> = {
			ArrowLeft: -1,
			ArrowRight: 1,
			ArrowUp: -3,
			ArrowDown: 3
		};
		if (event.key in step) {
			event.preventDefault();
			focusDay = clamp(addMonths(focusDay, step[event.key]!), minDay, maxDay);
			void focusGrid();
		}
	}

	async function toggleView() {
		view = view === 'days' ? 'months' : 'days';
		await focusGrid();
	}
</script>

{#snippet calendar()}
	<div class="dp-head">
		<button
			type="button"
			class="dp-title"
			aria-expanded={view === 'months'}
			aria-label={view === 'days'
				? `${monthName(focusDay.m)} ${focusDay.y}, choose month and year`
				: 'Back to days'}
			onclick={toggleView}
		>
			{view === 'days' ? `${monthName(focusDay.m)} ${focusDay.y}` : `${focusDay.y}`}
			<ChevronDown size={14} strokeWidth={2} aria-hidden="true" />
		</button>
		<div class="dp-nav">
			<button
				type="button"
				class="dp-arrow"
				aria-label={view === 'days' ? 'Previous month' : 'Previous year'}
				disabled={view === 'days' ? !canPrev : !!minDay && focusDay.y <= minDay.y}
				onclick={() => shiftMonth(view === 'days' ? -1 : -12)}
				><ChevronLeft size={16} strokeWidth={2} aria-hidden="true" /></button
			>
			<button
				type="button"
				class="dp-arrow"
				aria-label={view === 'days' ? 'Next month' : 'Next year'}
				disabled={view === 'days' ? !canNext : !!maxDay && focusDay.y >= maxDay.y}
				onclick={() => shiftMonth(view === 'days' ? 1 : 12)}
				><ChevronRight size={16} strokeWidth={2} aria-hidden="true" /></button
			>
		</div>
	</div>

	{#if view === 'days'}
		<div
			class="dp-grid"
			role="grid"
			aria-label={`${monthName(focusDay.m)} ${focusDay.y}`}
			bind:this={grid}
			tabindex="-1"
			onkeydown={gridKey}
		>
			<div class="dp-row" role="row">
				{#each ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'] as w, i (w)}
					<span class="dp-wd" role="columnheader"
						><abbr
							title={['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][
								i
							]}>{w}</abbr
						></span
					>
				{/each}
			</div>
			{#each weeks as week, w (w)}
				<div class="dp-row" role="row">
					{#each week as day, i (i)}
						<span class="dp-cell" role="gridcell" aria-selected={same(day, chosen) || undefined}>
							{#if day}
								{@const allowed = within(day, minDay, maxDay)}
								<button
									type="button"
									class="dp-day"
									class:on={same(day, chosen)}
									class:today={same(day, today)}
									tabindex={same(day, focusDay) ? 0 : -1}
									data-focus={same(day, focusDay)}
									aria-label={spokenLabel(day)}
									aria-current={same(day, today) ? 'date' : undefined}
									aria-disabled={allowed ? undefined : 'true'}
									onclick={() => (allowed ? choose(day) : undefined)}
									onfocus={() => (focusDay = day)}>{day.d}</button
								>
							{/if}
						</span>
					{/each}
				</div>
			{/each}
		</div>
	{:else}
		<div class="dp-months" role="group" aria-label={`Months of ${focusDay.y}`}>
			{#each Array.from({ length: 12 }, (_, i) => i + 1) as m (m)}
				{@const allowed = monthAllowed(focusDay.y, m)}
				<button
					type="button"
					class="dp-month"
					class:on={!!chosen && chosen.y === focusDay.y && chosen.m === m}
					tabindex={m === focusDay.m ? 0 : -1}
					data-month-focus={m === focusDay.m}
					disabled={!allowed}
					aria-label={`${monthName(m)} ${focusDay.y}`}
					onclick={() => pickMonth(focusDay.y, m)}
					onkeydown={monthsKey}>{shortMonth(m)}</button
				>
			{/each}
		</div>
	{/if}

	<div class="dp-quick">
		{#if within(today, minDay, maxDay)}
			<button type="button" class="dp-chip" onclick={() => choose(today)}>Today</button>
		{/if}
		{#if within(yesterday, minDay, maxDay)}
			<button type="button" class="dp-chip" onclick={() => choose(yesterday)}>Yesterday</button>
		{/if}
		{#if clearable && value}
			<button type="button" class="dp-chip dp-clear" onclick={() => choose(null)}>Clear</button>
		{/if}
	</div>
{/snippet}

{#if enhanced}
	{#if name}<input type="hidden" {name} {value} {disabled} />{/if}
	<button
		type="button"
		{id}
		class="dp-field {className}"
		class:dp-invalid={invalid}
		bind:this={trigger}
		role="combobox"
		aria-haspopup="dialog"
		aria-expanded={open}
		aria-controls={open ? `${key}-panel` : undefined}
		aria-invalid={invalid ? 'true' : undefined}
		aria-describedby={describedby}
		{disabled}
		onclick={show}
	>
		<span class="dp-value" class:dp-placeholder={!chosen}
			>{chosen ? fieldLabel(chosen) : placeholder}</span
		>
		<CalendarIcon size={18} strokeWidth={1.8} aria-hidden="true" class="dp-icon" />
	</button>
{:else}
	<input
		{id}
		{name}
		class={className}
		type="date"
		{min}
		{max}
		{disabled}
		bind:value
		aria-invalid={invalid ? 'true' : undefined}
		aria-describedby={describedby}
	/>
{/if}

{#if open && mode === 'pop'}
	<div
		bind:this={pop}
		id={`${key}-panel`}
		class="dp-pop"
		class:up={place.up}
		popover="manual"
		role="dialog"
		tabindex="-1"
		aria-modal="false"
		aria-label={label}
		data-wheel-picker
		style:left={`${place.left}px`}
		style:top={`${place.top}px`}
		onkeydown={panelKey}
	>
		{@render calendar()}
	</div>
{:else if open}
	<dialog
		bind:this={sheet}
		id={`${key}-panel`}
		class="dp-sheet"
		aria-labelledby={`${key}-title`}
		data-wheel-picker
		onkeydown={panelKey}
		oncancel={(event) => {
			event.preventDefault();
			close();
		}}
		onclick={(event) => {
			if (event.target === sheet) close();
		}}
		{@attach sheetDrag({ close: () => close() })}
	>
		<div class="dp-sheet-body">
			<span class="dp-grip" aria-hidden="true" data-sheet-grab></span>
			<h2 id={`${key}-title`} data-sheet-grab>{label}</h2>
			<p class="dp-sub" data-sheet-grab>{chosen ? shortLabel(chosen) : 'No date chosen'}</p>
			{@render calendar()}
		</div>
	</dialog>
{/if}

<style>
	/* The field. A page's own class sets the box; these zero-specificity
	   defaults only lay out the text and icon. */
	:where(.dp-field) {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 10px;
		width: 100%;
		min-width: 0;
		color: var(--color-text);
		font: inherit;
		text-align: left;
		cursor: pointer;
	}

	.dp-field.dp-invalid {
		border-color: var(--color-danger);
	}

	.dp-field:disabled {
		cursor: not-allowed;
		opacity: var(--opacity-disabled, 0.5);
	}

	.dp-value {
		overflow: hidden;
		min-width: 0;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.dp-placeholder {
		color: var(--color-muted);
	}

	.dp-field :global(.dp-icon) {
		flex-shrink: 0;
		color: var(--color-muted);
	}

	/* ── Desktop: anchored (DP01) ── */
	.dp-pop {
		position: fixed;
		inset: auto;
		z-index: 60;
		display: flex;
		flex-direction: column;
		gap: 10px;
		width: 324px;
		margin: 0;
		padding: 16px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-16);
		background: var(--color-surface);
		color: var(--color-text);
		box-shadow: 0 18px 48px rgb(0 0 0 / 0.45);
		animation: dp-in 120ms ease-out;
	}

	.dp-pop.up {
		translate: 0 -100%;
	}

	/* ── Phones: bottom sheet (DP02) ── */
	.dp-sheet {
		width: 100%;
		max-width: 520px;
		max-height: 100dvh;
		margin: auto auto 0;
		padding: 0;
		border: 0;
		border-top: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 24px 24px 0 0;
		background: var(--color-surface);
		color: var(--color-text);
		animation: dp-rise 200ms ease-out;
	}

	.dp-sheet::backdrop {
		background: color-mix(in oklab, #000 60%, transparent);
	}

	.dp-sheet-body {
		display: flex;
		flex-direction: column;
		gap: 12px;
		padding: 12px 20px calc(28px + env(safe-area-inset-bottom));
	}

	.dp-grip {
		align-self: center;
		width: 40px;
		height: 4px;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--color-text) 24%, transparent);
	}

	.dp-sheet h2 {
		margin: 2px 0 0;
		color: var(--color-text);
		font-size: var(--text-20);
		font-weight: var(--font-weight-bold);
		line-height: var(--leading-28);
	}

	.dp-sub {
		margin: -10px 0 0;
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	/* ── The calendar ── */
	.dp-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
	}

	.dp-title {
		display: flex;
		align-items: center;
		gap: 6px;
		height: 36px;
		padding: 0 10px;
		border: 0;
		border-radius: 10px;
		background: var(--color-raised);
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.dp-title :global(svg) {
		color: var(--color-muted);
	}

	.dp-nav {
		display: flex;
		gap: 4px;
	}

	.dp-arrow {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 36px;
		height: 36px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: none;
		color: var(--color-text);
		cursor: pointer;
	}

	.dp-arrow:disabled {
		opacity: 0.35;
		cursor: default;
	}

	.dp-grid {
		display: flex;
		flex-direction: column;
		gap: 2px;
		outline: none;
	}

	.dp-row {
		display: grid;
		grid-template-columns: repeat(7, 1fr);
	}

	.dp-wd {
		padding: 4px 0 6px;
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: 16px;
		text-align: center;
	}

	.dp-wd abbr {
		text-decoration: none;
	}

	.dp-cell {
		display: flex;
		justify-content: center;
	}

	.dp-day {
		width: 40px;
		height: 40px;
		border: 1px solid transparent;
		border-radius: var(--radius-pill);
		background: none;
		color: var(--color-text);
		font: inherit;
		font-size: var(--text-14);
		font-variant-numeric: tabular-nums;
		cursor: pointer;
		-webkit-tap-highlight-color: transparent;
	}

	.dp-day:hover {
		background: var(--color-raised);
	}

	.dp-day:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 1px;
	}

	.dp-day.today {
		border-color: var(--color-accent);
		color: var(--color-accent-text, var(--color-accent));
		font-weight: var(--font-weight-semibold);
	}

	.dp-day.on {
		border-color: var(--color-accent);
		background: var(--color-accent);
		color: var(--button-primary-ink);
		font-weight: var(--font-weight-semibold);
	}

	.dp-day[aria-disabled='true'] {
		opacity: 0.3;
		cursor: not-allowed;
	}

	.dp-day[aria-disabled='true']:hover {
		background: none;
	}

	.dp-months {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 8px;
		padding: 4px 0;
	}

	.dp-month {
		height: 44px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-12);
		background: none;
		color: var(--color-text);
		font: inherit;
		font-size: var(--text-14);
		cursor: pointer;
	}

	.dp-month.on {
		border-color: var(--color-accent);
		background: var(--color-accent);
		color: var(--button-primary-ink);
		font-weight: var(--font-weight-semibold);
	}

	.dp-month:disabled {
		opacity: 0.3;
		cursor: not-allowed;
	}

	.dp-month:focus-visible,
	.dp-title:focus-visible,
	.dp-arrow:focus-visible,
	.dp-chip:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 1px;
	}

	.dp-quick {
		display: flex;
		gap: 8px;
		padding-top: 12px;
		border-top: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
	}

	.dp-quick:empty {
		display: none;
	}

	.dp-chip {
		height: 32px;
		padding: 0 12px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: color-mix(in oklab, var(--color-text) 85%, transparent);
		font: inherit;
		font-size: var(--text-12);
		font-weight: var(--font-weight-medium);
		cursor: pointer;
	}

	.dp-clear {
		margin-left: auto;
		background: none;
		color: var(--color-accent-text, var(--color-accent));
	}

	@media (max-width: 1023.98px) {
		.dp-day {
			width: 44px;
			height: 44px;
		}
	}

	@keyframes dp-in {
		from {
			opacity: 0;
		}
	}

	@keyframes dp-rise {
		from {
			translate: 0 40px;
			opacity: 0;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.dp-pop,
		.dp-sheet {
			animation: none;
		}
	}
</style>
