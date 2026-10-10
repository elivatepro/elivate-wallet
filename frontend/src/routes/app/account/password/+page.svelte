<!--
	Change password while signed in (Blueprint 14), Paper "App — Screens v4"
	Z08 (new password + PIN; owner decision 2026-10-09: no current password)
	and Z09 (done). A wrong PIN counts against the same 5 attempts as the PIN
	screen. Supabase Auth signs out every other device when the password
	changes; this one stays signed in. The password and PIN are sent once,
	never stored, and the rows remount after each try.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { goto } from '$app/navigation';
	import { Effect, Exit } from 'effect';
	import Check from '@lucide/svelte/icons/check';
	import { AccountRoutes } from '#lib/contract/account.js';
	import { PasswordChanged } from '#lib/contract/security.js';
	import { sendAccountCommand } from '#lib/client/api.js';
	import { failureOf, followGate } from '#lib/client/account.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import AccountHero from '#lib/ui/account/AccountHero.svelte';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import PasswordRow from '#lib/ui/account/PasswordRow.svelte';
	import PinRow from '#lib/ui/account/PinRow.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';
	import { MAX_PASSWORD, MIN_PASSWORD } from '../../../(auth)/credentials';

	const shell = getContext<Shell>('shell');
	const SELF = '/app/account/password';
	const PIN = /^[0-9]{4}$/;

	type Errors = { password?: string; pin?: string };
	let errors = $state<Errors>({});
	let formError = $state<string | null>(null);
	let busy = $state(false);
	let done = $state(false);
	/** Remounts the rows so no password or PIN stays in the DOM after a try. */
	let attempt = $state(0);

	const PASSWORD_REASONS: Record<string, string> = {
		too_short: `Use at least ${MIN_PASSWORD} characters.`,
		too_long: 'That password is too long.',
		weak_password: `Use at least ${MIN_PASSWORD} characters.`,
		same_password: 'Choose a password you haven’t used here before.'
	};

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		if (busy || !shell.online) return;
		const data = new FormData(event.currentTarget as HTMLFormElement);
		const password = String(data.get('password') ?? '');
		const pin = String(data.get('pin') ?? '');
		const next: Errors = {};
		if (password.length < MIN_PASSWORD) next.password = PASSWORD_REASONS.too_short;
		else if (password.length > MAX_PASSWORD) next.password = PASSWORD_REASONS.too_long;
		if (!PIN.test(pin)) next.pin = 'Enter your 4-digit PIN.';
		errors = next;
		formError = null;
		if (Object.keys(next).length) return;

		busy = true;
		const exit = await Effect.runPromiseExit(
			sendAccountCommand(
				AccountRoutes.changePassword.path,
				'POST',
				{ password, pin },
				PasswordChanged
			)
		);
		busy = false;
		attempt += 1;
		if (Exit.isSuccess(exit)) {
			done = true;
			return;
		}
		const failure = failureOf(exit);
		if (failure?._tag === 'BackendError') {
			if (failure.code === 'pin_incorrect') {
				const left = Number(failure.details.attemptsRemaining);
				errors = {
					pin: Number.isFinite(left)
						? `That PIN is incorrect. ${left} ${left === 1 ? 'try' : 'tries'} left.`
						: 'That PIN is incorrect.'
				};
				return;
			}
			if (failure.code === 'validation_error' && failure.details.field === 'password') {
				errors = {
					password:
						PASSWORD_REASONS[String(failure.details.reason ?? '')] ?? PASSWORD_REASONS.too_short
				};
				return;
			}
			if (failure.code === 'validation_error' && failure.details.field === 'pin') {
				errors = { pin: 'Enter your 4-digit PIN.' };
				return;
			}
			if (failure.code === 'rate_limited') {
				formError = 'Too many attempts. Wait a few minutes, then try again.';
				return;
			}
		}
		if (followGate(failure, SELF)) return;
		formError = 'We couldn’t change your password. Try again.';
	}
</script>

<svelte:head><title>Change password · Elivate Wallet</title></svelte:head>

<PageBar title="Password" back="/app/account" backLabel="Back to Profile & security" />

<div class="page">
	<AccountHero
		pose="account-pin-change"
		mobile={{ width: 118, height: 160, right: 10, bottom: -10 }}
		desktop={{ width: 182, height: 246, right: 72, bottom: -14 }}
	>
		<div class="text">
			<h1 class="title" tabindex="-1">Change password</h1>
			<p class="lead">
				{#if done}
					<span class="mob">Use it next time you sign in.</span><span class="desk"
						>Use it the next time you sign in.</span
					>
				{:else}
					<span class="mob">Confirm it with your PIN.</span><span class="desk"
						>Confirm with your PIN. Other devices will be signed out.</span
					>
				{/if}
			</p>
		</div>
	</AccountHero>

	{#if done}
		<div class="done" role="status">
			<span class="tick" aria-hidden="true"><Check size={20} strokeWidth={2.2} /></span>
			<span class="done-text">
				<span class="done-title">Password changed</span>
				<span class="done-line"
					>Your other devices were signed out. This one stays signed in. We sent a confirmation to
					your email.</span
				>
			</span>
		</div>
		<div class="actions">
			<button type="button" class="primary" onclick={() => goto('/app/account')}
				>Back to Profile & security</button
			>
		</div>
	{:else}
		<form onsubmit={submit} novalidate>
			{#if formError}<FormAlert message={formError} />{/if}
			{#key attempt}
				<div class="card">
					<PasswordRow
						id="password"
						name="password"
						label="New password"
						placeholder="Create a new password"
						minlength={MIN_PASSWORD}
						maxlength={MAX_PASSWORD}
						error={errors.password}
						autofocus
					/>
					<PinRow id="pin" name="pin" label="Your PIN" error={errors.pin} />
				</div>
			{/key}
			<div class="actions">
				<button
					type="submit"
					class="primary"
					disabled={busy || !shell.online}
					aria-busy={busy ? 'true' : undefined}>Save new password</button
				>
				<a class="secondary" href="/app/account">Cancel</a>
			</div>
			<p class="forgot"><a href="/pin/forgot">Forgot your PIN?</a></p>
		</form>
	{/if}
</div>

<style>
	.page,
	form {
		display: flex;
		flex-direction: column;
		gap: 24px;
	}

	.page {
		/* Slice 21: side margins on phones (cards touched the screen edges). */
		padding: 8px 16px 40px;
	}

	.text {
		display: flex;
		flex-direction: column;
		gap: 6px;
		max-width: 200px;
	}

	.title {
		color: #ffffff;
		font-size: 22px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 27px;
		outline: none;
	}

	.lead {
		color: #d5dadb;
		font-size: 13px;
		line-height: 18px;
	}

	.desk {
		display: none;
	}

	.card {
		display: flex;
		flex-direction: column;
		gap: 22px;
		padding: 20px;
		border: 1px solid #ffffff14;
		border-radius: 20px;
		background: var(--color-surface);
	}

	:global([data-theme='light']) .card {
		border-color: var(--color-border);
	}

	.actions {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.primary,
	.secondary {
		display: flex;
		align-items: center;
		justify-content: center;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: 15px;
		line-height: 18px;
		text-decoration: none;
		cursor: pointer;
	}

	.primary {
		height: 52px;
		border: 0;
		background-image: var(--button-primary-bg);
		box-shadow:
			#ffffff59 0px 1px 0px inset,
			var(--button-primary-glow) 0px 10px 28px -10px;
		color: #14100e;
		font-weight: var(--font-weight-semibold);
	}

	.primary:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	.secondary {
		height: 48px;
		color: #d5dadb;
		font-weight: var(--font-weight-medium);
	}

	:global([data-theme='light']) .secondary {
		color: var(--color-text);
	}

	.forgot {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.forgot a {
		color: inherit;
	}

	/* Paper Z09: the done card. */
	.done {
		display: flex;
		align-items: flex-start;
		gap: 14px;
		padding: 20px;
		border: 1px solid #ffffff14;
		border-radius: 20px;
		background: var(--color-surface);
	}

	:global([data-theme='light']) .done {
		border-color: var(--color-border);
	}

	.tick {
		display: inline-flex;
		flex-shrink: 0;
		align-items: center;
		justify-content: center;
		width: 36px;
		height: 36px;
		border-radius: var(--radius-pill);
		background: color-mix(in srgb, var(--color-success) 12%, transparent);
		color: var(--color-success);
	}

	.done-text {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.done-title {
		color: var(--color-text);
		font-size: 17px;
		font-weight: var(--font-weight-semibold);
		line-height: 22px;
	}

	.done-line {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: 21px;
	}

	@media (min-width: 1024px) {
		.page {
			padding: 0;
		}

		.text {
			gap: 8px;
			max-width: none;
		}

		.title {
			font-size: 36px;
			letter-spacing: -0.03em;
			line-height: 42px;
		}

		.lead {
			font-size: 15px;
			line-height: 22px;
		}

		.desk {
			display: inline;
		}

		.mob {
			display: none;
		}

		.card {
			gap: 0;
			width: 640px;
			max-width: 100%;
			padding: 0;
			overflow: clip;
		}

		.card > :global(.row) {
			padding: 22px 28px;
		}

		.card > :global(.row + .row) {
			border-top: 1px solid #ffffff0a;
		}

		.done {
			gap: 18px;
			width: 640px;
			max-width: 100%;
			padding: 28px;
		}

		.tick {
			width: 40px;
			height: 40px;
		}

		.done-title {
			font-size: 18px;
			line-height: 24px;
		}

		.done-line {
			font-size: 15px;
			line-height: 22px;
		}

		.actions {
			flex-direction: row;
			align-items: center;
			gap: 12px;
		}

		.primary {
			height: 48px;
			padding: 0 26px;
		}

		.secondary {
			height: 48px;
			padding: 0 24px;
			border: 1px solid #343a3c;
			color: var(--color-text);
		}

		:global([data-theme='light']) .secondary {
			border-color: var(--color-border);
		}
	}
</style>
