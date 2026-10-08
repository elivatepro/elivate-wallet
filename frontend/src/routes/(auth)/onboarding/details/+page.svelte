<!-- Wizard step 2 · "Is this you?". Paper "Onboarding — Invited member" 08. -->
<script lang="ts">
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import Check from '@lucide/svelte/icons/check';
	import Info from '@lucide/svelte/icons/info';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import WizardProgress from '#lib/ui/onboarding/WizardProgress.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	useRoot('onboard-confirm');
	const name = $derived(
		data.identity.legalName
			? [
					data.identity.legalName.given,
					...data.identity.legalName.middle,
					data.identity.legalName.surname
				].join(' ')
			: ''
	);
	const byLeader = $derived(data.identity.method === 'leader_review');
</script>

<svelte:head><title>Is this you? · Elivate Wallet</title></svelte:head>

<WizardProgress step={2} />
<AuthHeading
	eyebrow="Step 2 · Identity"
	title="Is this you?"
	lead="Your legal name comes from your national ID and is now locked to your account."
/>
<div class="card">
	<div class="who">
		<span class="badge" aria-hidden="true"><ShieldCheck size={20} strokeWidth={1.8} /></span>
		<div>
			<p class="name">{name}</p>
			<p class="how">
				<Check size={14} strokeWidth={2.2} aria-hidden="true" />{byLeader
					? 'Confirmed by a leader'
					: 'Verified with NIN'}
			</p>
		</div>
	</div>
	<div class="row">
		<span>Phone</span>
		<span class:muted={!data.phone}>{data.phone ?? 'Not on your ID record'}</span>
	</div>
</div>
{#if !data.phone}
	<p class="note">
		<Info size={14} strokeWidth={1.8} aria-hidden="true" />You’ll add your phone and a profile photo
		next.
	</p>
{/if}
<PrimaryButton label="Yes, that’s me" href="/onboarding/profile" />

<style>
	.card {
		border-radius: var(--radius-16);
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		background: color-mix(in oklab, var(--color-surface) 80%, transparent);
	}

	.who {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 16px;
	}

	.badge {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 44px;
		height: 44px;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--color-success) 14%, transparent);
		color: var(--color-success);
	}

	.name {
		color: var(--color-text);
		font-size: 17px;
		font-weight: var(--font-weight-semibold);
		line-height: 24px;
		overflow-wrap: anywhere;
	}

	.how {
		display: flex;
		align-items: center;
		gap: 6px;
		color: var(--color-success);
		font-size: 13px;
		line-height: 18px;
	}

	.row {
		display: flex;
		justify-content: space-between;
		gap: 12px;
		padding: 14px 16px;
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	.row span:last-child {
		color: var(--color-text);
		text-align: right;
	}

	.row .muted {
		color: var(--color-muted);
	}

	.note {
		display: flex;
		align-items: center;
		gap: 8px;
		color: var(--auth-body);
		font-size: 13px;
		line-height: 18px;
	}
</style>
