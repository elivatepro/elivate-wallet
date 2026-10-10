<!--
	One payment (Blueprint 16): Paper "App — Screens v2" B05/B06 (confirmed, the
	receipt), B07/B08 (still confirming) and v4 PL10d (not completed). Paystack
	sends the payer back here; the page only asks the server, which checks the
	payment with Paystack itself. The redirect proves nothing.
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext, onDestroy } from 'svelte';
	import { page } from '$app/state';
	import { PaymentView, type Payment } from '#lib/contract/billing.js';
	import { dayLabel, lastDayLabel, naira } from '#lib/billing.js';
	import { loadView } from '#lib/client/org.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import RootImage from '#lib/ui/RootImage.svelte';
	import type { RootPose } from '#lib/ui/root.svelte.js';

	const shell = getContext<Shell>('shell');
	const id = $derived(page.params.id ?? '');
	// Paystack appends ?trxref=&reference= when it sends the payer back.
	const returned = page.url.searchParams.has('reference') || page.url.searchParams.has('trxref');

	let payment = $state<Payment | null>(null);
	let loadError = $state<string | null>(null);
	let checking = $state(false);
	let polls = 0;
	let timer: ReturnType<typeof setTimeout> | undefined;

	async function check(forId: string) {
		checking = true;
		const result = await loadView(
			`/api/billing/payments/${forId}${returned ? '?returned=1' : ''}`,
			PaymentView
		);
		checking = false;
		// Another receipt was opened meanwhile: this answer is stale.
		if (forId !== id) return;
		if (!result.ok) {
			loadError = result.text;
			return;
		}
		payment = result.value.payment;
		loadError = null;
		clearTimeout(timer);
		// Webhooks usually land within seconds: poll for about a minute.
		if (payment.status === 'open' && polls < 20) {
			polls++;
			timer = setTimeout(() => check(forId), 3000);
		}
	}

	// One load per payment id: the page is reused when [id] changes (the bell).
	let loadedFor = '';
	$effect(() => {
		if (shell.state.kind !== 'ready') return;
		const current = id;
		if (current === loadedFor) return;
		loadedFor = current;
		clearTimeout(timer);
		payment = null;
		loadError = null;
		polls = 0;
		void check(current);
	});
	onDestroy(() => clearTimeout(timer));

	const phase = $derived(
		payment === null
			? null
			: payment.status === 'paid'
				? 'paid'
				: payment.status === 'open'
					? 'confirming'
					: 'unpaid'
	);
	const pose = $derived<RootPose>(
		phase === 'paid'
			? 'payment-confirmed'
			: phase === 'confirming'
				? 'payment-confirming'
				: 'income-refused'
	);
	const covers = $derived(
		payment?.coversFrom && payment.coversTo
			? `${dayLabel(payment.coversFrom)} – ${lastDayLabel(payment.coversTo)}`
			: null
	);
</script>

<svelte:head><title>Payment · Elivate Wallet</title></svelte:head>

<div class="result">
	{#if loadError && !payment}
		<div class="o-error" role="alert">
			<p>{loadError}</p>
			<button type="button" class="o-ghost" onclick={() => check(id)}>Try again</button>
		</div>
	{:else if !payment}
		<div class="o-skeleton" aria-hidden="true"></div>
	{:else}
		<div class="hero" aria-hidden="true">
			<div class="grain"></div>
			<RootImage {pose} class="hero-root" sizes="200px" eager />
		</div>
		<div class="headline">
			{#if phase === 'paid'}
				<span class="chip ok">Paid · confirmed</span>
				<h1>Payment confirmed</h1>
				<p class="lead">
					{payment.needsReview
						? 'We’ve verified your payment. Our team will apply it to your plan.'
						: 'We’ve verified your payment with Paystack.'}
				</p>
			{:else if phase === 'confirming'}
				<span class="chip wait">Waiting for Paystack</span>
				<h1>Still confirming your payment</h1>
				<p class="lead">Don’t pay again. This can take a few minutes.</p>
			{:else}
				<span class="chip bad">Not paid</span>
				<h1>Payment not completed</h1>
				<p class="lead">Paystack didn’t take this payment, so nothing was charged.</p>
			{/if}
		</div>

		<dl class="details">
			<div>
				<dt>Amount</dt>
				<dd class="amount">{naira(payment.amount)}</dd>
			</div>
			<div>
				<dt>Plan</dt>
				<dd>
					{payment.plan.name} · {payment.purpose === 'upgrade' ? 'upgrade' : 'yearly'}
				</dd>
			</div>
			{#if phase === 'paid' && covers}<div>
					<dt>Period</dt>
					<dd>{covers}</dd>
				</div>{/if}
			<div>
				<dt>Reference</dt>
				<dd class="ref">{payment.reference}</dd>
			</div>
		</dl>

		<div class="actions">
			{#if phase === 'paid'}
				<button type="button" class="o-ghost" onclick={() => window.print()}>Print receipt</button>
				<a class="o-primary" href="/app/billing">Back to Billing</a>
			{:else if phase === 'confirming'}
				<a class="o-ghost" href="/app/billing">Back to Billing</a>
				<button
					type="button"
					class="light"
					disabled={checking}
					aria-busy={checking}
					onclick={() => {
						polls = 0;
						void check(id);
					}}>Check again</button
				>
			{:else}
				<a class="o-ghost" href="/app/billing">Back to Billing</a>
				<a class="light" href="/app/billing">Try again</a>
			{/if}
		</div>
	{/if}
</div>

<style>
	.result {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 24px;
		width: 100%;
		max-width: 640px;
		margin: 0 auto;
		padding-top: 8px;
	}

	.hero {
		position: relative;
		width: 100%;
		height: 200px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 24px;
		background-color: #1a1d1e;
		background-image: url('/auth-bg/mobile-dark.jpg');
		background-size: cover;
		background-position: 50% 30%;
	}

	.grain {
		position: absolute;
		inset: 0;
		background-image: url('/auth-bg/grain-128.webp');
		background-size: 128px 128px;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}

	.hero :global(.hero-root) {
		position: absolute;
		left: 0;
		right: 0;
		margin-inline: auto;
		bottom: -8px;
		width: 150px;
		height: 200px;
	}

	.headline {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 10px;
		text-align: center;
	}

	.chip {
		padding: 4px 12px;
		border-radius: var(--radius-pill);
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: 16px;
	}

	.chip.ok {
		background: color-mix(in oklab, var(--color-success) 16%, transparent);
		color: var(--color-success);
	}

	.chip.wait {
		background: color-mix(in oklab, var(--color-warning) 16%, transparent);
		color: var(--color-warning);
	}

	.chip.bad {
		background: color-mix(in oklab, var(--color-danger) 16%, transparent);
		color: var(--color-danger);
	}

	h1 {
		margin: 0;
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 34px;
	}

	.lead {
		margin: 0;
		color: var(--color-muted);
		font-size: 15px;
		line-height: 20px;
	}

	.details {
		width: 100%;
		max-width: 480px;
		margin: 0;
		padding: 4px 20px;
		border: 1px solid var(--color-border);
		border-radius: 20px;
		background: var(--color-surface);
	}

	.details > div {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		min-height: 48px;
		border-bottom: 1px solid var(--color-border);
		font-size: 15px;
	}

	.details > div:last-child {
		border-bottom: 0;
	}

	.details dt {
		color: var(--color-muted);
	}

	.details dd {
		margin: 0;
		font-weight: var(--font-weight-medium);
		text-align: right;
	}

	.amount {
		font-size: 18px;
		font-variant-numeric: tabular-nums;
	}

	.ref {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 13px;
		font-weight: 400 !important;
		letter-spacing: var(--tracking-label);
	}

	.actions {
		display: flex;
		flex-wrap: wrap;
		justify-content: center;
		gap: 12px;
	}

	.actions a {
		text-decoration: none;
	}

	.light {
		display: inline-flex;
		align-items: center;
		min-height: 48px;
		padding: 0 24px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--color-text);
		color: var(--color-canvas);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	@media (min-width: 1024px) {
		.hero {
			height: 250px;
		}

		.hero :global(.hero-root) {
			width: 170px;
			height: 240px;
		}

		h1 {
			font-size: 40px;
			line-height: 46px;
		}
	}

	@media print {
		.hero,
		.actions {
			display: none;
		}
	}
</style>
