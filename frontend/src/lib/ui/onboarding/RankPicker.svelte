<!--
	Self-declared rank (W-02 step 5; Paper 09 field, 10 "Your rank" sheet).
	Without JS: a native <select>. With JS: a field that opens a bottom sheet
	with a scroll-snap wheel; each detent gives a short vibration where the
	device supports it (navigator.vibrate; iOS Safari ignores it). Arrow keys
	move the wheel; "Set rank" writes the hidden select the form submits.
	Rank is presentation only and grants nothing.
-->
<script lang="ts">
	import { onMount, tick, untrack } from 'svelte';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import Vibrate from '@lucide/svelte/icons/vibrate';
	import { RANKS } from '#lib/contract/identity.js';
	import { rankLabel } from '#lib/labels.js';

	let { value = null, error }: { value?: string | null; error?: string | null } = $props();

	let enhanced = $state(false);
	let open = $state(false);
	// Seeded once from the saved rank; the wheel owns it after that.
	let chosen = $state<string | null>(untrack(() => value));
	let centre = $state(
		untrack(() => Math.max(0, RANKS.indexOf((value ?? 'Executive Manager') as never)))
	);
	let wheel: HTMLDivElement | undefined = $state();
	let trigger: HTMLButtonElement | undefined = $state();
	let setButton: HTMLButtonElement | undefined = $state();

	const ROW = 52;
	onMount(() => (enhanced = true));

	async function show() {
		open = true;
		await tick();
		wheel?.scrollTo({ top: centre * ROW });
		wheel?.focus();
	}

	function close(save: boolean) {
		if (save) chosen = RANKS[centre] ?? null;
		open = false;
		trigger?.focus();
	}

	let frame = 0;
	function onScroll() {
		cancelAnimationFrame(frame);
		frame = requestAnimationFrame(() => {
			if (!wheel) return;
			const next = Math.min(RANKS.length - 1, Math.max(0, Math.round(wheel.scrollTop / ROW)));
			if (next !== centre) {
				centre = next;
				navigator.vibrate?.(8);
			}
		});
	}

	function onKey(event: KeyboardEvent) {
		if (event.key === 'Escape') return close(false);
		if (event.key === 'Enter') return close(true);
		const delta = event.key === 'ArrowDown' ? 1 : event.key === 'ArrowUp' ? -1 : 0;
		if (!delta || !wheel) return;
		event.preventDefault();
		const next = Math.min(RANKS.length - 1, Math.max(0, centre + delta));
		wheel.scrollTo({ top: next * ROW, behavior: 'smooth' });
	}

	function trap(event: KeyboardEvent) {
		if (event.key !== 'Tab') return;
		event.preventDefault();
		(document.activeElement === wheel ? setButton : wheel)?.focus();
	}
</script>

<div class="field">
	<label for="rank" id="rank-label">Your rank</label>
	<select
		id="rank"
		name="rank"
		class:hidden={enhanced}
		bind:value={chosen}
		aria-invalid={error ? 'true' : undefined}
	>
		<option value={null} disabled selected={chosen === null}>Select your rank</option>
		{#each RANKS as rank (rank)}<option value={rank}>{rankLabel(rank)}</option>{/each}
	</select>
	{#if enhanced}
		<button
			type="button"
			class="trigger"
			class:invalid={!!error}
			bind:this={trigger}
			aria-haspopup="dialog"
			aria-labelledby="rank-label rank-value"
			onclick={show}
		>
			<span id="rank-value" class:placeholder={!chosen}
				>{chosen ? rankLabel(chosen) : 'Select your rank'}</span
			>
			<ChevronDown size={18} strokeWidth={1.8} aria-hidden="true" />
		</button>
	{/if}
	{#if error}<p class="error">{error}</p>{/if}
</div>

{#if open}
	<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
	<div class="scrim" onclick={() => close(false)}></div>
	<div
		class="sheet"
		role="dialog"
		aria-modal="true"
		aria-labelledby="sheet-title"
		tabindex="-1"
		onkeydown={trap}
	>
		<span class="grip" aria-hidden="true"></span>
		<h2 id="sheet-title">Your rank</h2>
		<p class="sub">Scroll to choose. You can change it later.</p>
		<div class="wheel-wrap">
			<div class="lens" aria-hidden="true"><Vibrate size={16} strokeWidth={1.8} /></div>
			<div
				class="wheel"
				bind:this={wheel}
				role="listbox"
				tabindex="0"
				aria-label="Rank"
				aria-activedescendant={`rank-opt-${centre}`}
				onscroll={onScroll}
				onkeydown={onKey}
			>
				<div class="pad" aria-hidden="true"></div>
				{#each RANKS as rank, i (rank)}
					<div
						id={`rank-opt-${i}`}
						class="opt"
						class:on={i === centre}
						role="option"
						aria-selected={i === centre}
						data-distance={Math.min(2, Math.abs(i - centre))}
					>
						{rankLabel(rank)}
					</div>
				{/each}
				<div class="pad" aria-hidden="true"></div>
			</div>
		</div>
		<button type="button" class="set" bind:this={setButton} onclick={() => close(true)}
			>Set rank</button
		>
	</div>
{/if}

<style>
	.field {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	label {
		color: var(--auth-label);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	select,
	.trigger {
		display: flex;
		align-items: center;
		justify-content: space-between;
		height: 52px;
		padding: 0 16px;
		border-radius: var(--radius-12);
		border: 1px solid var(--auth-field-border);
		background: var(--auth-field-bg);
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		text-align: left;
		cursor: pointer;
	}

	select.hidden {
		position: absolute;
		width: 1px;
		height: 1px;
		opacity: 0;
		pointer-events: none;
	}

	.trigger.invalid {
		border-color: var(--color-danger);
	}

	.trigger :global(svg) {
		color: var(--color-muted);
	}

	.placeholder {
		color: var(--auth-placeholder);
	}

	.error {
		color: var(--color-danger);
		font-size: var(--text-14);
	}

	.scrim {
		position: fixed;
		inset: 0;
		z-index: 40;
		background: color-mix(in oklab, #000 var(--opacity-overlay), transparent);
	}

	.sheet {
		position: fixed;
		left: 0;
		right: 0;
		bottom: 0;
		z-index: 41;
		display: flex;
		flex-direction: column;
		gap: 4px;
		max-width: 520px;
		margin: 0 auto;
		padding: 12px 24px calc(28px + env(safe-area-inset-bottom));
		border-radius: 24px 24px 0 0;
		background: var(--color-surface);
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
	}

	@media (min-width: 1024px) {
		.sheet {
			bottom: 50%;
			transform: translateY(50%);
			border-radius: 24px;
		}
	}

	.grip {
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

	.sub {
		color: var(--auth-body);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.wheel-wrap {
		position: relative;
		margin: 12px 0 20px;
	}

	.lens {
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

	.wheel {
		height: 260px;
		overflow-y: auto;
		scroll-snap-type: y mandatory;
		/* Snapped rows land in the lens, two rows down. */
		scroll-padding-top: 104px;
		scrollbar-width: none;
		outline: none;
		mask-image: linear-gradient(transparent, #000 30%, #000 70%, transparent);
	}

	.wheel:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 4px;
	}

	.pad {
		height: 104px;
	}

	.opt {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 52px;
		scroll-snap-align: start;
		color: var(--color-muted);
		font-size: 17px;
		transition:
			color 120ms,
			font-size 120ms;
	}

	.opt[data-distance='2'] {
		opacity: 0.45;
	}

	.opt.on {
		color: var(--color-accent-label);
		font-size: 20px;
		font-weight: var(--font-weight-semibold);
	}

	.set {
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

	@media (prefers-reduced-motion: reduce) {
		.opt {
			transition: none;
		}
	}
</style>
