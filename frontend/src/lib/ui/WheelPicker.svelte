<!--
	Blueprint 24: the one picker behind every member-app dropdown (the
	onboarding rank sheet, generalised).
	- Without JS: a native <select> with the same id, name and options, so forms
	  and server actions work as before.
	- With JS: a field (role combobox) that opens a sheet with a scroll-snap
	  wheel of 52 px rows. Each detent vibrates briefly where the browser allows
	  it (navigator.vibrate: Android Chrome; iOS has no web vibration) and the
	  lens gives a small visual tick (none with reduced motion). Tapping a row
	  turns the wheel to it; the confirm button (or Enter) chooses it.
	- Long lists (more than 8, or `searchable`) get a search field: filter as you
	  type, arrows move the wheel, Enter chooses, "No matches" when empty.
	- Keyboard: arrows, Page Up/Down, Home/End, type-ahead, Enter/Space, Escape;
	  Tab stays inside the sheet. A bottom sheet on phones; a centred dialog on
	  desktop. It is a native modal <dialog> (top layer), so it also works inside
	  Bits UI dialogs.
	- A form field (`name`) is posted through a hidden input once enhanced.
-->
<script lang="ts" module>
	// Pickers created after the first hydration start enhanced (no select flash).
	let hydrated = false;
</script>

<script lang="ts">
	import { onMount, tick } from 'svelte';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import Search from '@lucide/svelte/icons/search';
	import Vibrate from '@lucide/svelte/icons/vibrate';
	import {
		filterOptions,
		keyTarget,
		rowAt,
		shouldSearch,
		startIndex,
		typeahead,
		type WheelOption
	} from './wheel-picker.js';

	type Props = {
		options: readonly WheelOption[];
		value?: string | null;
		/** The field's id: a page's `<label for>` names the picker through it. */
		id: string;
		/** Form field name; posted with the form (hidden input once enhanced). */
		name?: string;
		/** What is chosen ("Bank"): the wheel's name and the default sheet title. */
		label: string;
		/** Sheet heading; defaults to `label`. */
		title?: string;
		/** A line under the heading. */
		sub?: string;
		/** The confirm button. */
		confirmText?: string;
		placeholder?: string;
		/** Fixed text on the field instead of the chosen option (filters, "+ Add"). */
		triggerText?: string;
		/** Accessible name when the page has no `<label for={id}>`. */
		ariaLabel?: string;
		/** Classes for the field (and the fallback select); else the variant's look. */
		class?: string;
		variant?: 'field' | 'auth';
		/** Size the field to its text instead of the full width (chips). */
		fit?: boolean;
		/** An action ("+ Add"): every confirmed row calls `onchange`; the field keeps no value. */
		action?: boolean;
		invalid?: boolean;
		describedby?: string;
		disabled?: boolean;
		required?: boolean;
		searchable?: boolean | 'auto';
		searchPlaceholder?: string;
		emptyText?: string;
		/** The row the wheel starts on when nothing is chosen yet. */
		initial?: string | null;
		onchange?: (value: string) => void;
	};

	let {
		options,
		value = $bindable(null),
		id,
		name,
		label,
		title,
		sub,
		confirmText = 'Done',
		placeholder = 'Choose one',
		triggerText,
		ariaLabel,
		class: className,
		variant = 'field',
		fit = false,
		action = false,
		invalid = false,
		describedby,
		disabled = false,
		required = false,
		searchable = 'auto',
		searchPlaceholder = 'Search',
		emptyText,
		initial = null,
		onchange
	}: Props = $props();

	const ROW = 52;
	const key = $props.id();
	let enhanced = $state(hydrated);
	let open = $state(false);
	let query = $state('');
	/** The row under the lens (follows the scroll). */
	let centre = $state(0);
	/** A row the wheel is turning to (keyboard, tap); wins until it arrives. */
	let pending = $state<number | null>(null);
	let touch = $state(false);
	let lift = $state(0);

	/**
	 * Slice 30 (owner 2026-10-11): on a desktop with a mouse the picker is a
	 * list anchored under the field (field width, search for long lists); the
	 * wheel stays on phones and touch screens.
	 */
	let mode = $state<'wheel' | 'list'>('wheel');
	let pick = $state(0);
	let place = $state({ left: 0, top: 0, width: 0, maxHeight: 320, up: false });
	let pop: HTMLDivElement | undefined = $state();
	let list: HTMLUListElement | undefined = $state();

	let trigger: HTMLButtonElement | undefined = $state();
	let dialog: HTMLDialogElement | undefined = $state();
	let wheel: HTMLDivElement | undefined = $state();
	let lens: HTMLDivElement | undefined = $state();

	const search = $derived(shouldSearch(searchable, options.length));
	const shown = $derived(filterOptions(options, query));
	const active = $derived(pending ?? centre);
	const current = $derived(options.find((o) => o.value === value) ?? null);
	const pickable = $derived(!!shown[active] && !shown[active].disabled);
	const look = $derived(className ?? `wp-${variant}`);
	const optionText = (o: WheelOption) => (o.hint ? `${o.label} · ${o.hint}` : o.label);

	onMount(() => {
		hydrated = true;
		enhanced = true;
		return () => {
			release();
			detachList();
		};
	});

	const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

	async function show() {
		if (disabled || open) return;
		query = '';
		pending = null;
		centre = startIndex(options, value, initial);
		touch = matchMedia('(pointer: coarse)').matches;
		mode = matchMedia('(min-width: 1024px) and (pointer: fine)').matches ? 'list' : 'wheel';
		if (mode === 'list') return showList();
		open = true;
		await tick();
		if (!dialog) return;
		// Where focus starts: the search field with a keyboard at hand, else the
		// wheel (so a phone doesn't open its keyboard over the wheel).
		const first = search && !touch ? dialog.querySelector('input') : wheel;
		first?.setAttribute('autofocus', '');
		lastRow = -1;
		dialog.showModal();
		hold();
		jump(centre, false);
	}

	function close(save: boolean) {
		if (mode === 'list') return closeList(save ? pick : null);
		if (save) {
			const chosen = shown[active];
			if (!chosen || chosen.disabled) return;
			if (action) onchange?.(chosen.value);
			else if (chosen.value !== value) {
				value = chosen.value;
				onchange?.(chosen.value);
			}
		}
		dialog?.close();
		open = false;
		release();
		trigger?.focus();
	}

	// Page scroll lock and the on-screen keyboard (iOS keeps the layout
	// viewport, so the sheet lifts above the keyboard by hand).
	let held = false;
	let overflow = '';
	function fitKeyboard() {
		const vv = window.visualViewport;
		lift = vv ? Math.max(0, Math.round(window.innerHeight - vv.height - vv.offsetTop)) : 0;
	}
	function hold() {
		if (held) return;
		held = true;
		overflow = document.documentElement.style.overflow;
		document.documentElement.style.overflow = 'hidden';
		window.visualViewport?.addEventListener('resize', fitKeyboard);
		window.visualViewport?.addEventListener('scroll', fitKeyboard);
	}
	function release() {
		if (!held) return;
		held = false;
		document.documentElement.style.overflow = overflow;
		window.visualViewport?.removeEventListener('resize', fitKeyboard);
		window.visualViewport?.removeEventListener('scroll', fitKeyboard);
		lift = 0;
	}

	function jump(index: number, smooth: boolean) {
		wheel?.scrollTo({
			top: index * ROW,
			behavior: smooth && !reduced() ? 'smooth' : 'instant'
		});
	}

	function go(index: number) {
		if (index === active) return;
		pending = index;
		jump(index, true);
	}

	// One detent: a short vibration where supported, and a tick of the lens.
	let lastRow = -1;
	function detent() {
		navigator.vibrate?.(8);
		if (!reduced()) {
			lens?.animate([{ transform: 'scaleY(1.06)' }, { transform: 'scaleY(1)' }], {
				duration: 120,
				easing: 'ease-out'
			});
		}
	}

	let frame = 0;
	function onScroll() {
		cancelAnimationFrame(frame);
		frame = requestAnimationFrame(() => {
			if (!wheel) return;
			const row = rowAt(wheel.scrollTop, ROW, shown.length);
			if (row !== lastRow) {
				if (lastRow !== -1) detent();
				lastRow = row;
			}
			if (pending === null) centre = row;
			else if (row === pending) {
				centre = row;
				pending = null;
			}
		});
	}

	function settle() {
		if (!wheel) return;
		centre = rowAt(wheel.scrollTop, ROW, shown.length);
		pending = null;
	}

	// A hand on the wheel takes over from a turn in progress.
	function grab() {
		if (pending !== null) settle();
	}

	async function onQuery() {
		pending = null;
		await tick();
		centre = query.trim() ? 0 : startIndex(shown, value, initial);
		lastRow = -1;
		jump(centre, false);
	}

	let typed = '';
	let typedAt = 0;
	function wheelKey(event: KeyboardEvent) {
		if (event.key === 'Enter' || event.key === ' ') {
			event.preventDefault();
			return close(true);
		}
		const to = keyTarget(event.key, active, shown.length);
		if (to !== null) {
			event.preventDefault();
			return go(to);
		}
		if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
			const now = Date.now();
			typed = now - typedAt > 700 ? event.key : typed + event.key;
			typedAt = now;
			const hit = typeahead(shown, typed, active);
			if (hit !== null) go(hit);
		}
	}

	function searchKey(event: KeyboardEvent) {
		if (event.key === 'Enter') {
			event.preventDefault();
			return close(true);
		}
		if (['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp'].includes(event.key)) {
			event.preventDefault();
			const to = keyTarget(event.key, active, shown.length);
			if (to !== null) go(to);
		}
	}

	function sheetKey(event: KeyboardEvent) {
		if (event.key === 'Escape') {
			// Ours alone: a Bits UI dialog underneath must stay open.
			event.preventDefault();
			event.stopPropagation();
			return close(false);
		}
		if (event.key !== 'Tab' || !dialog) return;
		event.preventDefault();
		event.stopPropagation();
		const stops = [
			...dialog.querySelectorAll<HTMLElement>('input, [role="listbox"], button:not(:disabled)')
		];
		const at = stops.indexOf(document.activeElement as HTMLElement);
		const next = (at + (event.shiftKey ? -1 : 1) + stops.length) % stops.length;
		stops[next]?.focus();
	}

	function onBackdrop(event: MouseEvent) {
		// The dialog box itself is only hit outside the sheet (the backdrop).
		if (event.target === dialog) close(false);
	}
	// ── The anchored list (desktop) ──
	const GAP = 6;
	const LIST_MAX = 320;
	function measure() {
		if (!trigger) return;
		const r = trigger.getBoundingClientRect();
		const width = Math.max(r.width, 220);
		const below = window.innerHeight - r.bottom - GAP - 8;
		const above = r.top - GAP - 8;
		const up = below < Math.min(LIST_MAX, 200) && above > below;
		const room = Math.max(120, Math.min(LIST_MAX, up ? above : below));
		const left = Math.min(Math.max(8, r.left), window.innerWidth - width - 8);
		place = { left, top: up ? r.top - GAP : r.bottom + GAP, width, maxHeight: room, up };
	}

	async function showList() {
		pick = Math.max(0, startIndex(options, value, initial));
		measure();
		open = true;
		await tick();
		if (!pop) return;
		try {
			pop.showPopover();
		} catch {
			// No Popover API: it still shows, fixed under the field.
		}
		(search ? pop.querySelector<HTMLInputElement>('input') : list)?.focus();
		scrollPick();
		document.addEventListener('pointerdown', outside, true);
		window.addEventListener('resize', measure);
		window.addEventListener('scroll', onPageScroll, true);
	}

	function closeList(index: number | null) {
		if (index !== null) {
			const chosen = shown[index];
			if (!chosen || chosen.disabled) return;
			if (action) onchange?.(chosen.value);
			else if (chosen.value !== value) {
				value = chosen.value;
				onchange?.(chosen.value);
			}
		}
		detachList();
		try {
			pop?.hidePopover();
		} catch {
			// not shown as a popover
		}
		open = false;
		trigger?.focus();
	}

	/** The list's page listeners (also on unmount, e.g. Back while it is open). */
	function detachList() {
		document.removeEventListener('pointerdown', outside, true);
		window.removeEventListener('resize', measure);
		window.removeEventListener('scroll', onPageScroll, true);
	}

	function outside(event: PointerEvent) {
		const target = event.target as Node;
		if (pop?.contains(target) || trigger?.contains(target)) return;
		closeList(null);
	}

	/** The page scrolled under the list: follow the field (the list's own scroll is fine). */
	function onPageScroll(event: Event) {
		if (pop && event.target instanceof Node && pop.contains(event.target)) return;
		measure();
	}

	function scrollPick() {
		list
			?.querySelector<HTMLElement>(`[data-index="${pick}"]`)
			?.scrollIntoView({ block: 'nearest' });
	}

	async function movePick(to: number) {
		pick = to;
		await tick();
		scrollPick();
	}

	function listKey(event: KeyboardEvent) {
		if (event.key === 'Escape') {
			// Ours alone: a Bits UI dialog underneath must stay open.
			event.preventDefault();
			event.stopPropagation();
			return closeList(null);
		}
		if (event.key === 'Tab') return closeList(null);
		if (event.key === 'Enter' || (event.key === ' ' && event.target === list)) {
			event.preventDefault();
			return closeList(pick);
		}
		// In the search field Home/End edit the text; only the arrows and pages move.
		const inSearch = event.target instanceof HTMLInputElement;
		if (inSearch && !['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp'].includes(event.key)) return;
		const to = keyTarget(event.key, pick, shown.length);
		if (to !== null) {
			event.preventDefault();
			return void movePick(to);
		}
		if (
			event.target === list &&
			event.key.length === 1 &&
			!event.ctrlKey &&
			!event.metaKey &&
			!event.altKey
		) {
			const now = Date.now();
			typed = now - typedAt > 700 ? event.key : typed + event.key;
			typedAt = now;
			const hit = typeahead(shown, typed, pick);
			if (hit !== null) void movePick(hit);
		}
	}

	function onListQuery() {
		pick = 0;
		void tick().then(scrollPick);
	}
</script>

{#if enhanced}
	{#if name}<input type="hidden" {name} value={value ?? ''} {disabled} />{/if}
	<button
		type="button"
		{id}
		class="wp-trigger {look}"
		class:wp-fit={fit}
		bind:this={trigger}
		role="combobox"
		aria-haspopup={mode === 'list' ? 'listbox' : 'dialog'}
		aria-expanded={open}
		aria-controls={open ? (mode === 'list' ? `${key}-list` : `${key}-dialog`) : undefined}
		aria-label={ariaLabel}
		aria-invalid={invalid ? 'true' : undefined}
		aria-required={required ? 'true' : undefined}
		aria-describedby={describedby}
		{disabled}
		onclick={show}
	>
		{#if triggerText}
			<span class="wp-text">{triggerText}</span>
		{:else if current}
			<span class="wp-text"
				>{current.label}{#if current.hint}<span class="wp-hint">{` · ${current.hint}`}</span
					>{/if}</span
			>
		{:else}
			<span class="wp-text wp-placeholder">{placeholder}</span>
		{/if}
		<ChevronDown class="wp-chevron" size={16} strokeWidth={1.8} aria-hidden="true" />
	</button>
{:else}
	<select
		{id}
		{name}
		class="wp-native {look}"
		class:wp-fit={fit}
		{disabled}
		{required}
		aria-label={ariaLabel}
		aria-invalid={invalid ? 'true' : undefined}
		aria-describedby={describedby}
		onchange={(event) => {
			value = event.currentTarget.value;
			onchange?.(value);
		}}
	>
		{#if !current}<option value="" disabled selected>{placeholder}</option>{/if}
		{#each options as o (o.value)}
			<option value={o.value} disabled={o.disabled} selected={o.value === value}
				>{optionText(o)}</option
			>
		{/each}
	</select>
{/if}

{#if open && mode === 'list'}
	<div
		bind:this={pop}
		class="wp-pop"
		class:up={place.up}
		popover="manual"
		data-wheel-picker
		style:left={`${place.left}px`}
		style:top={`${place.top}px`}
		style:width={`${place.width}px`}
		style:max-height={`${place.maxHeight}px`}
		onkeydown={listKey}
		role="presentation"
	>
		{#if search}
			<label class="wp-pop-search">
				<Search size={15} strokeWidth={2} aria-hidden="true" />
				<span class="visually-hidden">Search {label.toLowerCase()}</span>
				<input
					type="search"
					role="combobox"
					aria-expanded="true"
					aria-controls={`${key}-list`}
					aria-autocomplete="list"
					aria-activedescendant={shown.length ? `${key}-opt-${pick}` : undefined}
					placeholder={searchPlaceholder}
					autocomplete="off"
					autocapitalize="off"
					spellcheck="false"
					bind:value={query}
					oninput={onListQuery}
				/>
			</label>
		{/if}
		{#if shown.length}
			<ul
				bind:this={list}
				class="wp-pop-list"
				id={`${key}-list`}
				role="listbox"
				tabindex={search ? -1 : 0}
				aria-label={label}
				aria-activedescendant={`${key}-opt-${pick}`}
			>
				{#each shown as o, i (o.value)}
					<!-- The listbox (or search) holds focus; rows are pointer targets. -->
					<!-- svelte-ignore a11y_click_events_have_key_events -->
					<li
						id={`${key}-opt-${i}`}
						class="wp-pop-opt"
						class:on={i === pick}
						class:chosen={o.value === value}
						role="option"
						data-index={i}
						aria-selected={o.value === value}
						aria-disabled={o.disabled ? 'true' : undefined}
						onpointermove={() => (pick = i)}
						onclick={() => closeList(i)}
					>
						<span class="wp-opt-label">{o.label}</span>
						{#if o.hint}<span class="wp-opt-hint">{o.hint}</span>{/if}
					</li>
				{/each}
			</ul>
		{:else}
			<p class="wp-pop-empty" role="status">{emptyText ?? `Nothing matches “${query.trim()}”.`}</p>
		{/if}
	</div>
{:else if open}
	<!-- svelte-ignore a11y_click_events_have_key_events -->
	<dialog
		bind:this={dialog}
		id={`${key}-dialog`}
		class="wp-dialog"
		data-wheel-picker
		aria-labelledby={`${key}-title`}
		onclick={onBackdrop}
		onkeydown={sheetKey}
		oncancel={(event) => {
			event.preventDefault();
			close(false);
		}}
	>
		<div class="wp-sheet" style:--wp-lift={`${lift}px`}>
			<span class="wp-grip" aria-hidden="true"></span>
			<h2 id={`${key}-title`}>{title ?? label}</h2>
			{#if sub}<p class="wp-sub">{sub}</p>{/if}
			{#if search}
				<label class="wp-search">
					<Search size={16} strokeWidth={2} aria-hidden="true" />
					<span class="visually-hidden">Search {label.toLowerCase()}</span>
					<input
						type="search"
						role="combobox"
						aria-expanded="true"
						aria-controls={`${key}-list`}
						aria-autocomplete="list"
						aria-activedescendant={shown.length ? `${key}-opt-${active}` : undefined}
						placeholder={searchPlaceholder}
						autocomplete="off"
						autocapitalize="off"
						spellcheck="false"
						enterkeyhint="done"
						bind:value={query}
						oninput={onQuery}
						onkeydown={searchKey}
					/>
				</label>
			{/if}
			{#if shown.length}
				<div class="wp-wheel-wrap">
					<div class="wp-lens" bind:this={lens} aria-hidden="true">
						<Vibrate size={16} strokeWidth={1.8} />
					</div>
					<div
						class="wp-wheel"
						bind:this={wheel}
						id={`${key}-list`}
						role="listbox"
						tabindex="0"
						aria-label={label}
						aria-activedescendant={`${key}-opt-${active}`}
						onscroll={onScroll}
						onscrollend={settle}
						onpointerdown={grab}
						onwheel={grab}
						ontouchstart={grab}
						onkeydown={wheelKey}
					>
						<div class="wp-pad" aria-hidden="true"></div>
						{#each shown as o, i (o.value)}
							<!-- The listbox holds focus (aria-activedescendant); rows are pointer targets. -->
							<!-- svelte-ignore a11y_click_events_have_key_events, a11y_interactive_supports_focus -->
							<div
								id={`${key}-opt-${i}`}
								class="wp-opt"
								class:on={i === active}
								role="option"
								aria-selected={i === active}
								aria-disabled={o.disabled ? 'true' : undefined}
								data-distance={Math.min(2, Math.abs(i - active))}
								onclick={() => go(i)}
							>
								<span class="wp-opt-label">{o.label}</span>
								{#if o.hint}<span class="wp-opt-hint">{o.hint}</span>{/if}
							</div>
						{/each}
						<div class="wp-pad" aria-hidden="true"></div>
					</div>
				</div>
			{:else}
				<p class="wp-empty" role="status">
					{emptyText ?? `Nothing matches “${query.trim()}”.`}
					<span>Check the spelling or try fewer letters.</span>
				</p>
			{/if}
			<p class="visually-hidden" aria-live="polite">
				{query.trim() && shown.length
					? `${shown.length} ${shown.length === 1 ? 'match' : 'matches'}`
					: ''}
			</p>
			<button
				type="button"
				class="wp-set"
				data-wheel-confirm
				disabled={!pickable}
				onclick={() => close(true)}>{confirmText}</button
			>
		</div>
	</dialog>
{/if}

<style>
	/* ── The anchored list (desktop, Slice 30) ── */
	.wp-pop {
		position: fixed;
		inset: auto;
		z-index: 60;
		display: flex;
		flex-direction: column;
		margin: 0;
		padding: 6px;
		overflow: hidden;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-12);
		background: var(--color-surface);
		color: var(--color-text);
		box-shadow: 0 18px 48px rgb(0 0 0 / 0.45);
		animation: wp-pop-in 120ms ease-out;
	}

	.wp-pop.up {
		translate: 0 -100%;
	}

	.wp-pop-search {
		display: flex;
		flex-shrink: 0;
		align-items: center;
		gap: 8px;
		height: 38px;
		margin-bottom: 6px;
		padding: 0 10px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-8);
		color: var(--color-muted);
	}

	.wp-pop-search:focus-within {
		border-color: var(--color-accent);
	}

	.wp-pop-search input {
		flex: 1;
		min-width: 0;
		border: 0;
		outline: none;
		background: none;
		color: var(--color-text);
		font: inherit;
		font-size: var(--text-14);
	}

	.wp-pop-list {
		margin: 0;
		padding: 0;
		overflow-y: auto;
		list-style: none;
		outline: none;
		overscroll-behavior: contain;
	}

	.wp-pop-opt {
		display: flex;
		flex-direction: column;
		justify-content: center;
		gap: 2px;
		min-height: 40px;
		padding: 8px 12px;
		border-radius: var(--radius-8);
		font-size: var(--text-14);
		line-height: 18px;
		cursor: pointer;
	}

	.wp-pop-opt.on {
		background: var(--color-raised);
	}

	.wp-pop-opt.chosen .wp-opt-label {
		color: var(--color-accent-text, var(--color-accent));
		font-weight: var(--font-weight-semibold);
	}

	.wp-pop-opt[aria-disabled='true'] {
		cursor: not-allowed;
		opacity: var(--opacity-disabled, 0.5);
	}

	.wp-pop-opt .wp-opt-hint {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: 16px;
	}

	.wp-pop-empty {
		padding: 12px;
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	@keyframes wp-pop-in {
		from {
			opacity: 0;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.wp-pop {
			animation: none;
		}
	}

	/* The field. A page's own class (o-input, en-box, s-input…) sets the box;
	   these zero-specificity defaults only lay out the text and chevron. */
	:where(.wp-trigger) {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 10px;
		width: 100%;
		min-width: 0;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		text-align: left;
		cursor: pointer;
	}

	:where(.wp-fit) {
		width: auto;
	}

	.wp-trigger:disabled {
		cursor: not-allowed;
		opacity: var(--opacity-disabled, 0.5);
	}

	.wp-text {
		overflow: hidden;
		min-width: 0;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.wp-hint,
	.wp-placeholder {
		color: var(--color-muted);
	}

	.wp-trigger :global(.wp-chevron) {
		flex-shrink: 0;
		color: var(--color-muted);
	}

	:where(.wp-field) {
		height: 48px;
		padding: 0 16px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-12);
		background: var(--color-canvas);
	}

	:where(.wp-auth) {
		height: 52px;
		padding: 0 16px;
		border: 1px solid var(--auth-field-border);
		border-radius: var(--radius-12);
		background: var(--auth-field-bg);
	}

	:where(.wp-auth) .wp-placeholder {
		color: var(--auth-placeholder);
	}

	:where(.wp-field, .wp-auth):focus-visible {
		border-color: var(--color-accent);
		box-shadow: color-mix(in oklab, var(--color-accent) 20%, transparent) 0 0 0 3px;
		outline: none;
	}

	:where(.wp-field, .wp-auth)[aria-invalid='true'] {
		border-color: var(--color-danger);
	}

	:where(.wp-native) {
		width: 100%;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
	}

	/* The sheet: a native modal dialog, so it sits in the top layer. */
	.wp-dialog {
		position: fixed;
		inset: auto 0 0;
		width: 100%;
		max-width: 520px;
		max-height: 100dvh;
		margin: 0 auto;
		padding: 0;
		border: 0;
		background: transparent;
		color: inherit;
		overflow: visible;
	}

	.wp-dialog::backdrop {
		background: color-mix(in oklab, #000 var(--opacity-overlay), transparent);
	}

	.wp-sheet {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 12px 24px calc(28px + env(safe-area-inset-bottom));
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 24px 24px 0 0;
		background: var(--color-surface);
		color: var(--color-text);
		text-align: left;
		transform: translateY(calc(-1 * var(--wp-lift, 0px)));
		/* Short screens (a phone on its side): the sheet scrolls, never off screen. */
		max-height: calc(100dvh - var(--wp-lift, 0px));
		overflow-y: auto;
		overscroll-behavior: contain;
		animation: wp-rise 200ms cubic-bezier(0.2, 0.8, 0.2, 1);
	}

	.wp-sheet > * {
		flex-shrink: 0;
	}

	@keyframes wp-rise {
		from {
			opacity: 0;
			translate: 0 24px;
		}
	}

	@media (min-width: 1024px) {
		.wp-dialog {
			inset: 0;
			height: fit-content;
			margin: auto;
		}

		.wp-sheet {
			padding-bottom: 28px;
			border-radius: 24px;
		}

		.wp-grip {
			display: none;
		}
	}

	.wp-grip {
		align-self: center;
		width: 40px;
		height: 4px;
		margin-bottom: 12px;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--color-text) 24%, transparent);
	}

	h2 {
		color: var(--color-text);
		font-size: var(--text-20);
		font-weight: var(--font-weight-bold);
		line-height: var(--leading-28);
	}

	.wp-sub {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.wp-search {
		display: flex;
		align-items: center;
		gap: 10px;
		height: 44px;
		margin-top: 12px;
		padding: 0 14px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-12);
		background: var(--color-canvas);
		color: var(--color-muted);
	}

	.wp-search:focus-within {
		border-color: var(--color-accent);
		outline: 2px solid var(--focus-ring);
		outline-offset: 1px;
	}

	.wp-search input {
		flex: 1;
		min-width: 0;
		height: 100%;
		padding: 0;
		border: 0;
		outline: none;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		/* 16 px keeps iOS from zooming in on focus. */
		font-size: 16px;
	}

	.wp-search input::placeholder {
		color: var(--color-muted);
	}

	.wp-wheel-wrap {
		position: relative;
		margin: 12px 0 20px;
	}

	.wp-lens {
		position: absolute;
		left: -8px;
		right: -8px;
		top: 104px;
		height: 52px;
		display: flex;
		align-items: center;
		justify-content: flex-end;
		padding-right: 14px;
		border-radius: var(--radius-12);
		border: 1px solid color-mix(in oklab, var(--color-accent) 50%, transparent);
		background: color-mix(in oklab, var(--color-accent) 14%, transparent);
		color: var(--color-accent-label);
		pointer-events: none;
	}

	.wp-wheel {
		height: 260px;
		overflow-y: auto;
		overscroll-behavior: contain;
		scroll-snap-type: y mandatory;
		/* Snapped rows land in the lens, two rows down. */
		scroll-padding-top: 104px;
		scrollbar-width: none;
		outline: none;
		mask-image: linear-gradient(transparent, #000 30%, #000 70%, transparent);
	}

	.wp-wheel::-webkit-scrollbar {
		display: none;
	}

	.wp-wheel:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 4px;
	}

	.wp-pad {
		height: 104px;
	}

	.wp-opt {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		height: 52px;
		padding: 0 40px;
		scroll-snap-align: start;
		color: var(--color-muted);
		font-size: 17px;
		line-height: 22px;
		cursor: pointer;
		transition:
			color 120ms,
			font-size 120ms;
	}

	.wp-opt-label,
	.wp-opt-hint {
		overflow: hidden;
		max-width: 100%;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.wp-opt-hint {
		font-size: 12px;
		line-height: 16px;
	}

	.wp-opt[data-distance='2'] {
		opacity: 0.45;
	}

	.wp-opt[aria-disabled='true'] {
		opacity: 0.35;
	}

	.wp-opt.on {
		color: var(--color-accent-label);
		font-size: 20px;
		font-weight: var(--font-weight-semibold);
		line-height: 24px;
	}

	.wp-opt.on .wp-opt-hint {
		font-size: 12px;
		font-weight: var(--font-weight-regular);
	}

	.wp-empty {
		display: flex;
		flex-direction: column;
		justify-content: center;
		gap: 4px;
		height: 260px;
		margin: 12px 0 20px;
		color: var(--color-text);
		font-size: var(--text-16);
		line-height: var(--leading-24, 24px);
		text-align: center;
	}

	.wp-empty span {
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	.wp-set {
		height: 56px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--button-primary-bg);
		box-shadow: var(--auth-button-shadow);
		color: var(--button-primary-ink);
		font: inherit;
		font-size: var(--text-16);
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.wp-set:disabled {
		cursor: not-allowed;
		opacity: var(--opacity-disabled, 0.5);
	}

	.wp-set:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 3px;
	}

	@media (prefers-reduced-motion: reduce) {
		.wp-opt {
			transition: none;
		}

		.wp-sheet {
			animation: none;
		}
	}
</style>
