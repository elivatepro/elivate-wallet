<!--
	New password after a Recovery link, Paper "App — Screens v4" Z03 (owner
	approved 2026-10-08): verified email (read-only), new password, then the
	PIN as usual. Once saved, Z10 (approved 2026-10-09): other devices were
	signed out (Supabase Auth does that on every password change), PIN next.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import Check from '@lucide/svelte/icons/check';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import Field from '#lib/ui/auth/Field.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import LockedField from '#lib/ui/auth/LockedField.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { MIN_PASSWORD } from '../credentials';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	let busy = $state(false);
</script>

<svelte:head
	><title>{data.saved ? 'Password changed' : 'Set a new password'} · Elivate Wallet</title
	></svelte:head
>

{#if data.saved}
	<AuthHeading
		eyebrow="Recovery"
		title="Password changed"
		lead="Next, confirm it’s you with your PIN."
	/>
	<div class="saved">
		<p class="note" role="status">
			<span class="tick" aria-hidden="true"><Check size={16} strokeWidth={2.2} /></span>
			<span
				>Any other devices signed in to your account were signed out. We sent a confirmation to your
				email.</span
			>
		</p>
		<PrimaryButton label="Continue to PIN" href="/workspaces" />
	</div>
{:else}
	<AuthHeading
		eyebrow="Recovery"
		title="Set a new password"
		lead="Then you’ll confirm with your PIN as usual."
	/>
	<form
		method="POST"
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
		<div class="fields">
			{#if data.email}
				<LockedField id="account-email" label="Email" value={data.email} locked={false}>
					{#snippet trailing()}
						<span class="verified"
							><Check size={14} strokeWidth={2} aria-hidden="true" />Verified</span
						>
					{/snippet}
				</LockedField>
			{/if}
			<Field
				id="password"
				name="password"
				type="password"
				label="New password"
				placeholder="Create a new password"
				autocomplete="new-password"
				minlength={MIN_PASSWORD}
				error={form?.error}
			/>
		</div>
		<PrimaryButton label="Save new password" {busy} />
	</form>
{/if}

<style>
	form,
	.fields {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	form {
		gap: 28px;
	}

	.verified {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		color: var(--color-success);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		letter-spacing: 0.14em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.saved {
		display: flex;
		flex-direction: column;
		gap: 28px;
	}

	.note {
		display: flex;
		align-items: flex-start;
		gap: 14px;
		padding: 16px 18px;
		border: 1px solid color-mix(in srgb, var(--color-text) 8%, transparent);
		border-radius: 14px;
		background: color-mix(in srgb, var(--color-text) 4%, transparent);
		color: var(--color-text);
		font-size: 15px;
		line-height: 22px;
	}

	.tick {
		display: inline-flex;
		flex-shrink: 0;
		align-items: center;
		justify-content: center;
		width: 32px;
		height: 32px;
		border-radius: 999px;
		background: color-mix(in srgb, var(--color-success) 12%, transparent);
		color: var(--color-success);
	}

	@media (min-width: 1024px) {
		form,
		.saved {
			gap: 32px;
		}
	}
</style>
