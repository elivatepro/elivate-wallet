<!-- NGN / USD segmented switch (Paper H04 header, T04 card corner). Changes the view only, never data. -->
<script lang="ts">
	import type { Currency } from '#lib/contract/ledger.js';

	let {
		currencies,
		currency = $bindable(),
		size = 'md'
	}: { currencies: ReadonlyArray<Currency>; currency: Currency; size?: 'sm' | 'md' } = $props();
</script>

<div class="switch" data-size={size} role="group" aria-label="Currency">
	{#each currencies as c (c)}
		<button type="button" aria-pressed={c === currency} onclick={() => (currency = c)}>{c}</button>
	{/each}
</div>

<style>
	.switch {
		display: inline-flex;
		gap: 2px;
		padding: 4px;
		border-radius: var(--radius-pill);
		border: 1px solid color-mix(in oklab, var(--color-text) 10%, transparent);
		background: color-mix(in oklab, var(--color-canvas) 60%, transparent);
	}

	button {
		min-width: 64px;
		height: 36px;
		padding: 0 14px;
		border: 0;
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-muted);
		font: inherit;
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	button[aria-pressed='true'] {
		background: var(--color-text);
		color: var(--color-canvas);
	}

	[data-size='sm'] button {
		min-width: 44px;
		height: 28px;
		padding: 0 10px;
		font-size: 12px;
	}

	[data-size='sm'] {
		border-color: #ffffff1f;
		background: #11131473;
	}

	[data-size='sm'] button {
		color: #a9b0b3;
	}

	[data-size='sm'] button[aria-pressed='true'] {
		background: #f2f4f4;
		color: #111314;
	}
</style>
