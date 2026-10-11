<!--
	Paper "Authentication v2" 13d/13m · Apply to start a network (Blueprint 19).
	Root with clipboard and pen; desktop pairs name/phone and team/rank in a
	wider panel. The rank is the shared wheel picker (Blueprint 24).
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import { FOUNDER_RANKS } from '#lib/contract/founders.js';
	import { rankLabel } from '#lib/labels.js';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import Turnstile from '#lib/ui/auth/Turnstile.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);
	let turnstile: Turnstile | undefined = $state();
	let checkFailed = $state(false);

	useRoot('apply', 'sm');

	const values = $derived(form?.values);
	const errors = $derived(form && 'errors' in form ? form.errors : undefined);
</script>

<svelte:head><title>Start your network · Elivate Wallet</title></svelte:head>

<AuthHeading
	eyebrow="Apply first"
	title="Start your network"
	lead="For 4 Ruby Director and above. Elivate reviews every application and emails you an invitation once it is approved."
/>

<form
	class="apply-form"
	method="POST"
	novalidate
	use:enhance={() => {
		busy = true;
		return async ({ update }) => {
			await update({ reset: false });
			busy = false;
			turnstile?.reset();
		};
	}}
>
	{#if form?.message}<FormAlert message={form.message} />{/if}
	<div class="grid">
		<Field
			id="full-name"
			name="fullName"
			label="Full name"
			placeholder="Adaeze Okafor"
			autocomplete="name"
			maxlength={100}
			value={values?.fullName ?? ''}
			error={errors?.fullName}
		/>
		<Field
			id="phone"
			name="phone"
			label="Phone number"
			placeholder="0803 000 0000"
			autocomplete="tel"
			maxlength={24}
			value={values?.phone ?? ''}
			error={errors?.phone}
		/>
		<div class="wide">
			<Field
				id="email"
				name="email"
				type="email"
				label="Email address"
				placeholder="you@example.com"
				autocomplete="email"
				value={values?.email ?? data.signedInEmail ?? ''}
				error={errors?.email}
			/>
		</div>
		<Field
			id="team-name"
			name="teamName"
			label="Team name"
			placeholder="e.g. Cedar Network"
			autocomplete="organization"
			maxlength={100}
			value={values?.teamName ?? ''}
			error={errors?.teamName}
		/>
		<div class="field">
			<label for="rank">Your rank</label>
			<WheelPicker
				id="rank"
				name="rank"
				variant="auth"
				label="Rank"
				title="Your rank"
				placeholder="Choose one"
				confirmText="Set rank"
				required
				options={FOUNDER_RANKS.map((rank) => ({ value: rank, label: rankLabel(rank) }))}
				value={values?.rank ?? null}
				invalid={!!errors?.rank}
				describedby={errors?.rank ? 'rank-hint rank-error' : 'rank-hint'}
			/>
			<p class="hint" id="rank-hint">4 Ruby Director or above only</p>
			{#if errors?.rank}<p class="error" id="rank-error">{errors.rank}</p>{/if}
		</div>
	</div>
	<Turnstile
		bind:this={turnstile}
		bind:failed={checkFailed}
		siteKey={data.turnstileSiteKey}
		action="apply"
		retryLabel="send your application"
		theme={data.theme === 'system' ? 'auto' : data.theme}
	/>
	<div class="actions">
		<PrimaryButton label="Send application" {busy} disabled={checkFailed} />
		{#if data.signedInEmail}
			<AltLink label="Back to workspaces" href="/workspaces?switch" />
		{:else}
			<AltLink prompt="Already with Elivate?" label="Sign in" href="/sign-in" />
		{/if}
	</div>
</form>

<style>
	form,
	.grid,
	.actions,
	.field {
		display: flex;
		flex-direction: column;
	}

	form {
		gap: 28px;
	}

	.grid {
		gap: 20px;
	}

	.actions {
		gap: 20px;
	}

	.field {
		gap: 8px;
	}

	label {
		color: var(--auth-label);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	.hint {
		color: var(--auth-body);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.error {
		color: var(--color-danger);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	@media (min-width: 1024px) {
		form {
			gap: 28px;
		}

		/* 13d: a 560 px panel with paired fields (outranks the gate layout's 500 px). */
		:global(div.auth .frame .content:has(.stage) .panel:has(form.apply-form)) {
			width: 560px;
			padding: 40px;
		}

		.grid {
			display: grid;
			grid-template-columns: 1fr 1fr;
			gap: 24px 16px;
			align-items: start;
		}

		.grid > :global(*) {
			min-width: 0;
		}

		.wide {
			grid-column: 1 / -1;
		}
	}
</style>
