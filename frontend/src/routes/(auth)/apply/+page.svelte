<!--
	Paper "Authentication v2" 13d/13m · Apply to start a network (Blueprint 19).
	Root with clipboard and pen; desktop pairs name/phone and team/rank in a
	wider panel. The rank is a native select (accepted deviation, like banks).
-->
<script lang="ts">
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import { enhance } from '$app/forms';
	import { FOUNDER_RANK_LABELS, FOUNDER_RANKS } from '#lib/contract/founders.js';
	import AltLink from '#lib/ui/auth/AltLink.svelte';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import Turnstile from '#lib/ui/auth/Turnstile.svelte';
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
	lead="For Ruby Director 4 and above. Elivate reviews every application and emails you an invitation once it is approved."
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
			<div class="select" class:invalid={!!errors?.rank}>
				<select
					id="rank"
					name="rank"
					required
					aria-invalid={errors?.rank ? 'true' : undefined}
					aria-describedby={errors?.rank ? 'rank-hint rank-error' : 'rank-hint'}
				>
					<option value="" disabled selected={!values?.rank}>Choose your rank</option>
					{#each FOUNDER_RANKS as rank (rank)}
						<option value={rank} selected={values?.rank === rank}>{FOUNDER_RANK_LABELS[rank]}</option>
					{/each}
				</select>
				<ChevronDown size={18} strokeWidth={1.6} aria-hidden="true" />
			</div>
			<p class="hint" id="rank-hint">Ruby Director 4 or above only</p>
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

	.select {
		position: relative;
		display: flex;
		align-items: center;
		height: 52px;
		border-radius: var(--radius-12);
		border: 1px solid var(--auth-field-border);
		background: var(--auth-field-bg);
		color: var(--color-muted);
	}

	.select:focus-within {
		border-color: var(--color-accent);
		box-shadow: color-mix(in oklab, var(--color-accent) 20%, transparent) 0px 0px 0px 3px;
	}

	.select.invalid {
		border-color: var(--color-danger);
	}

	select {
		flex: 1;
		min-width: 0;
		height: 100%;
		padding: 0 44px 0 16px;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		appearance: none;
		outline: none;
		cursor: pointer;
	}

	select:has(option[value='']:checked) {
		color: var(--auth-placeholder);
	}

	option {
		color: var(--color-text);
		background: var(--color-surface);
	}

	.select :global(svg) {
		position: absolute;
		right: 16px;
		pointer-events: none;
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

		/* 13d: a 560 px panel with paired fields. */
		:global(.panel:has(.apply-form)) {
			width: 560px;
		}

		.grid {
			display: grid;
			grid-template-columns: 1fr 1fr;
			gap: 24px 16px;
			align-items: start;
		}

		.wide {
			grid-column: 1 / -1;
		}
	}
</style>
