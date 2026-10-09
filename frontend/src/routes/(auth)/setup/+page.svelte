<!--
	Founder setup (Blueprint 16): Paper "App — Screens v4" PL01 (name your
	network), PL02 (choose a plan, 7-day trial) and PL11 (trial already used:
	pay yearly). One POST at the end; the name step stays in this page.
-->
<script lang="ts">
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { bandPeople, naira } from '#lib/billing.js';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();

	// The first render's values (a refused POST comes back with them).
	const initial = untrack(() => ({ form, plans: data.setup.plans }));
	let step = $state<'name' | 'plan'>(initial.form?.step === 'plan' ? 'plan' : 'name');
	let name = $state(initial.form?.name ?? '');
	let nameError = $state<string | null>(initial.form?.errors?.name ?? null);
	let planKey = $state<string>(initial.plans[0]?.key ?? 'band_400');
	let busy = $state(false);

	useRoot(
		() => (step === 'name' ? 'setup-name' : 'seat-limit'),
		() => 'lg'
	);

	const trial = $derived(data.setup.trialAvailable && planKey === 'band_400');
	/** A refused start hands its key back so a retry can't start twice. */
	const key = $derived(
		(form as { idempotencyKey?: string } | null)?.idempotencyKey ?? data.idempotencyKey
	);

	function next(event: SubmitEvent) {
		event.preventDefault();
		const typed = new FormData(event.currentTarget as HTMLFormElement).get('name');
		const clean = String(typed ?? '')
			.trim()
			.replace(/\s+/g, ' ');
		if (clean.length < 2 || clean.length > 100) {
			nameError = 'Use 2–100 characters.';
			return;
		}
		name = clean;
		nameError = null;
		step = 'plan';
	}
</script>

<svelte:head
	><title>{step === 'name' ? 'Name your network' : 'Choose a plan'} · Elivate Wallet</title
	></svelte:head
>

{#if step === 'name'}
	<AuthHeading
		eyebrow="Set up · 1 of 2"
		title="Name your network"
		lead="Everyone you invite will see this name."
	/>
	<form onsubmit={next} novalidate>
		<Field
			id="network-name"
			name="name"
			label="Network name"
			placeholder="Cedar Network"
			autocomplete="organization"
			value={name}
			error={nameError ?? undefined}
		/>
		<div class="actions">
			<PrimaryButton label="Continue" />
			<AltLink label="Back to workspaces" href="/workspaces?switch" />
		</div>
	</form>
{:else}
	<AuthHeading
		eyebrow="Set up · 2 of 2"
		title="Choose a plan"
		lead={data.setup.trialAvailable
			? `Start free for ${data.setup.trialDays} days, then pay yearly.`
			: 'You’ve used your free trial. Pay yearly to open this network.'}
	/>
	{#if data.setup.pending.length > 0}
		{#each data.setup.pending as pending (pending.membershipId)}
			<form method="POST" action="?/resume" class="resume">
				<input type="hidden" name="membershipId" value={pending.membershipId} />
				<span>{pending.name} is waiting for payment.</span>
				<button type="submit" class="resume-link">Pay now</button>
			</form>
		{/each}
	{/if}
	<form
		method="POST"
		action="?/start"
		novalidate
		use:enhance={() => {
			busy = true;
			return async ({ update }) => {
				await update({ reset: false });
				busy = false;
			};
		}}
	>
		{#if form?.message}<FormAlert message={form.message} />{/if}
		<input type="hidden" name="name" value={name} />
		<input type="hidden" name="trial" value={trial ? 'true' : 'false'} />
		<input type="hidden" name="idempotencyKey" value={key} />
		<fieldset class="plans">
			<legend class="sr-only">Plan</legend>
			{#each data.setup.plans as plan (plan.key)}
				<label class="plan" class:on={planKey === plan.key}>
					<input type="radio" name="planKey" value={plan.key} bind:group={planKey} />
					<span class="dot" aria-hidden="true"></span>
					<span class="text">
						<span class="name">{bandPeople(plan.seatCap)}</span>
						<span class="sub"
							>{data.setup.trialAvailable && plan.key === 'band_400'
								? `${data.setup.trialDays} days free, then yearly`
								: 'Yearly'}</span
						>
					</span>
					<span class="price">{naira(plan.price)}</span>
				</label>
			{/each}
		</fieldset>
		<div class="actions">
			<PrimaryButton
				label={trial ? `Start ${data.setup.trialDays}-day free trial` : 'Continue to payment'}
				{busy}
			/>
			<button type="button" class="back" onclick={() => (step = 'name')}>Back</button>
		</div>
	</form>
{/if}

<style>
	form {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	.actions {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.plans {
		display: flex;
		flex-direction: column;
		gap: 10px;
		margin: 0;
		padding: 0;
		border: 0;
	}

	.plan {
		position: relative;
		display: flex;
		align-items: center;
		gap: 14px;
		min-height: 64px;
		padding: 12px 16px;
		border: 1px solid var(--auth-field-border);
		border-radius: var(--radius-12);
		background: var(--auth-field-bg);
		cursor: pointer;
	}

	.plan.on {
		border-color: color-mix(in oklab, var(--color-text) 28%, transparent);
		background: color-mix(in oklab, var(--color-text) 8%, var(--auth-field-bg));
	}

	.plan input {
		position: absolute;
		opacity: 0;
		pointer-events: none;
	}

	.plan:has(input:focus-visible) {
		outline: 2px solid var(--focus-ring);
		outline-offset: 2px;
	}

	.dot {
		flex-shrink: 0;
		width: 20px;
		height: 20px;
		border: 1.5px solid var(--color-muted);
		border-radius: 50%;
	}

	.plan.on .dot {
		border-color: var(--color-accent);
		background: radial-gradient(circle, var(--color-accent) 0 5px, transparent 5.5px);
	}

	.text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.name {
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
	}

	.sub {
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
	}

	.price {
		flex-shrink: 0;
		font-size: 14px;
		font-weight: var(--font-weight-semibold);
		font-variant-numeric: tabular-nums;
	}

	.back {
		align-self: center;
		border: 0;
		background: transparent;
		color: var(--color-muted);
		font: inherit;
		font-size: var(--text-14);
		cursor: pointer;
	}

	.resume {
		flex-direction: row;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 12px 16px;
		border: 1px solid var(--auth-field-border);
		border-radius: var(--radius-12);
		font-size: var(--text-14);
	}

	.resume-link {
		border: 0;
		background: transparent;
		color: var(--color-accent);
		font: inherit;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
		white-space: nowrap;
	}
</style>
