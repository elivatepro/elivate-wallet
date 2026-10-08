<!--
	Balance card, Paper "App — Screens v3" H04/H06 (desktop 280 px, mobile
	T04-style): "Available to withdraw" with the hide-amounts eye, the amount,
	Posted/Reserved chips, Root on the coin stack. On mobile the currency
	switch sits inside the card top-right (owner rule); it appears only when
	the person actually holds more than one currency. Stays dark in both themes.
-->
<script lang="ts">
	import Eye from '@lucide/svelte/icons/eye';
	import EyeOff from '@lucide/svelte/icons/eye-off';
	import type { Currency, CurrencyBalance } from '#lib/contract/ledger.js';
	import { formatMoney, hiddenMoney } from '#lib/money.js';
	import RootImage from '#lib/ui/RootImage.svelte';
	import CurrencySwitch from './CurrencySwitch.svelte';

	let {
		balance,
		currencies,
		currency = $bindable(),
		hidden,
		onToggleHidden
	}: {
		balance: CurrencyBalance;
		currencies: ReadonlyArray<Currency>;
		currency: Currency;
		hidden: boolean;
		onToggleHidden: () => void;
	} = $props();

	const show = (amount: string) => (hidden ? hiddenMoney(currency) : formatMoney(amount, currency));
</script>

<section class="card" aria-label="Balance">
	<div class="shade" aria-hidden="true"></div>
	<div class="grain" aria-hidden="true"></div>
	<RootImage pose="home" class="card-root" sizes="(min-width: 1024px) 196px, 120px" eager />
	<div class="top">
		<span class="label">Available to withdraw</span>
		<button
			type="button"
			class="eye"
			aria-label={hidden ? 'Show amounts' : 'Hide amounts'}
			aria-pressed={hidden}
			onclick={onToggleHidden}
		>
			{#if hidden}<EyeOff size={18} strokeWidth={1.5} />{:else}<Eye
					size={18}
					strokeWidth={1.5}
				/>{/if}
		</button>
		{#if currencies.length > 1}
			<div class="switch-mobile"><CurrencySwitch {currencies} bind:currency size="sm" /></div>
		{/if}
	</div>
	<div class="bottom">
		<p class="amount">{show(balance.available)}</p>
		<div class="chips">
			<span class="chip">Posted {show(balance.posted)}</span>
			<span class="chip">Reserved {show(balance.reserved)}</span>
		</div>
	</div>
</section>

<style>
	.card {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: space-between;
		gap: 40px;
		min-height: 236px;
		padding: 22px 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 22px;
		background-color: #1a1d1e;
		background-image: url('/auth-bg/mobile-dark.jpg');
		background-size: cover;
		background-position: 50% 30%;
		background-origin: border-box;
		isolation: isolate;
		color: #ffffff;
	}

	.shade,
	.grain {
		position: absolute;
		inset: 0;
		pointer-events: none;
	}

	.shade {
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(18.5% -0.002 -0.003 / 92%) 0%,
			oklab(18.5% -0.002 -0.003 / 55%) 55%,
			oklab(18.5% -0.002 -0.003 / 0%) 100%
		);
	}

	.grain {
		background-image: url('/auth-bg/grain-256.png');
		background-size: 256px 256px;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}

	.card :global(.card-root) {
		position: absolute;
		right: 4px;
		bottom: -12px;
		width: 120px;
		height: 162px;
	}

	.top,
	.bottom {
		position: relative;
	}

	.top {
		display: flex;
		align-items: center;
		gap: 4px;
	}

	.label {
		color: #d5dadb;
		font-size: var(--text-14);
		line-height: 18px;
	}

	.eye {
		display: flex;
		align-items: center;
		justify-content: center;
		width: var(--hit-min);
		height: var(--hit-min);
		margin: -12px 0;
		border: 0;
		border-radius: var(--radius-pill);
		background: transparent;
		color: #d5dadb;
		cursor: pointer;
	}

	.switch-mobile {
		margin-left: auto;
	}

	.bottom {
		display: flex;
		flex-direction: column;
		gap: 12px;
		max-width: calc(100% - 110px);
	}

	.amount {
		font-size: 36px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.035em;
		line-height: 40px;
		font-variant-numeric: tabular-nums;
		overflow-wrap: anywhere;
	}

	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
	}

	.chip {
		padding: 6px 12px;
		border-radius: var(--radius-pill);
		border: 1px solid #ffffff1a;
		background: #1113148c;
		color: #f2f4f4;
		font-size: 13px;
		line-height: 16px;
		font-variant-numeric: tabular-nums;
	}

	@media (min-width: 1024px) {
		.card {
			height: 280px;
			padding: 28px 32px;
			border-radius: var(--radius-24);
		}

		.card :global(.card-root) {
			right: 36px;
			bottom: -18px;
			width: 196px;
			height: 264px;
		}

		.switch-mobile {
			display: none;
		}

		.amount {
			font-size: 64px;
			line-height: 68px;
		}

		.bottom {
			max-width: calc(100% - 260px);
		}
	}
</style>
