<!--
	Paystack hand-off, Paper "App — Screens v4" PL03: the amount, the year it
	covers and Elivate's PAY reference, then Paystack's own page. Payment is
	confirmed server-side when Paystack brings the payer back.
-->
<script lang="ts">
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { bandPeople, firstYearLabel, naira } from '#lib/billing.js';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	useRoot('withdraw', 'lg');

	const covers = firstYearLabel(new Date());
</script>

<svelte:head><title>Pay on Paystack · Elivate Wallet</title></svelte:head>

<AuthHeading
	eyebrow="Payment"
	title="Pay on Paystack"
	lead={data.plan
		? `${data.network} · ${bandPeople(data.plan.seatCap).toLowerCase()} · yearly`
		: 'Your network is waiting for its first payment.'}
/>
{#if data.message}<FormAlert message={data.message} />{/if}
{#if data.checkout && data.plan}
	<dl class="facts">
		<div>
			<dt>Amount</dt>
			<dd class="amount">{naira(data.checkout.amount ?? data.plan.price)}</dd>
		</div>
		<div>
			<dt>Covers</dt>
			<dd>{covers}</dd>
		</div>
		<div>
			<dt>Reference</dt>
			<dd class="ref">{data.checkout.reference}</dd>
		</div>
	</dl>
	<div class="actions">
		{#if data.checkout.authorizationUrl}
			<PrimaryButton
				label={`Pay ${naira(data.checkout.amount ?? data.plan.price)}`}
				href={data.checkout.authorizationUrl}
			/>
		{:else}
			<PrimaryButton label="Try again" href="/setup/pay" />
		{/if}
		<AltLink label="Back to workspaces" href="/workspaces?switch" />
	</div>
{:else}
	<div class="actions">
		<PrimaryButton label="Try again" href="/setup/pay" />
		<AltLink label="Back to workspaces" href="/workspaces?switch" />
	</div>
{/if}

<style>
	.facts {
		margin: 0;
		overflow: hidden;
		border: 1px solid var(--auth-field-border);
		border-radius: var(--radius-12);
		background: var(--auth-field-bg);
	}

	.facts > div {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		min-height: 46px;
		padding: 0 16px;
		border-bottom: 1px solid var(--auth-field-border);
		font-size: var(--text-14);
	}

	.facts > div:last-child {
		border-bottom: 0;
	}

	.facts dt {
		color: var(--color-muted);
	}

	.facts dd {
		margin: 0;
		text-align: right;
	}

	.amount {
		font-weight: var(--font-weight-semibold);
	}

	.ref {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 13px;
		letter-spacing: var(--tracking-label);
	}

	.actions {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}
</style>
