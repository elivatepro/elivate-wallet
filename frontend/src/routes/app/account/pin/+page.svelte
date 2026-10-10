<!--
	Change transaction PIN, Paper "App — Screens v2" S05 (desktop) / S06
	(mobile). Current PIN, new PIN, confirm (Blueprint 10). A wrong current PIN
	counts against the same 5 attempts as the PIN screen; the fifth locks it
	and leads to the email reset. Other devices must enter the new PIN.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { goto } from '$app/navigation';
	import { Effect, Exit } from 'effect';
	import { AccountRoutes } from '#lib/contract/account.js';
	import { SecurityState } from '#lib/contract/security.js';
	import { sendAccountCommand } from '#lib/client/api.js';
	import { failureOf, followGate } from '#lib/client/account.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import AccountHero from '#lib/ui/account/AccountHero.svelte';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import PinRow from '#lib/ui/account/PinRow.svelte';
	import FormAlert from '#lib/ui/auth/FormAlert.svelte';

	const shell = getContext<Shell>('shell');
	const SELF = '/app/account/pin';
	const PIN = /^[0-9]{4}$/;

	type Errors = { currentPin?: string; pin?: string; pinConfirm?: string };
	let errors = $state<Errors>({});
	let formError = $state<string | null>(null);
	let busy = $state(false);
	let done = $state(false);
	/** Remounts the rows so no PIN stays in the DOM after a try. */
	let attempt = $state(0);

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		if (busy || !shell.online) return;
		const data = new FormData(event.currentTarget as HTMLFormElement);
		const currentPin = String(data.get('currentPin') ?? '');
		const pin = String(data.get('pin') ?? '');
		const pinConfirm = String(data.get('pinConfirm') ?? '');
		const next: Errors = {};
		if (!PIN.test(currentPin)) next.currentPin = 'Enter your current 4-digit PIN.';
		if (!PIN.test(pin)) next.pin = 'Choose a new 4-digit PIN.';
		else if (pin === currentPin) next.pin = 'Choose a PIN different from your current one.';
		if (PIN.test(pin) && pinConfirm !== pin) next.pinConfirm = 'The PINs don’t match.';
		errors = next;
		formError = null;
		if (Object.keys(next).length) return;

		busy = true;
		const exit = await Effect.runPromiseExit(
			sendAccountCommand(
				AccountRoutes.changePin.path,
				'POST',
				{ currentPin, pin, pinConfirm },
				SecurityState
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
					currentPin: Number.isFinite(left)
						? `That PIN is incorrect. ${left} ${left === 1 ? 'try' : 'tries'} left.`
						: 'That PIN is incorrect.'
				};
				return;
			}
			if (failure.code === 'validation_error') {
				const field = String(failure.details.field ?? '');
				errors =
					failure.details.reason === 'same_pin'
						? { pin: 'Choose a PIN different from your current one.' }
						: field === 'pinConfirm'
							? { pinConfirm: 'The PINs don’t match.' }
							: field === 'currentPin'
								? { currentPin: 'Enter your current 4-digit PIN.' }
								: { pin: 'Choose a new 4-digit PIN.' };
				return;
			}
		}
		if (followGate(failure, SELF)) return;
		formError = 'We couldn’t change your PIN. Try again.';
	}
</script>

<svelte:head><title>Change transaction PIN · Elivate Wallet</title></svelte:head>

<PageBar title="Transaction PIN" back="/app/account" backLabel="Back to Profile & security" />

<div class="page">
	<AccountHero
		pose="account-pin-change"
		mobile={{ width: 118, height: 160, right: 10, bottom: -10 }}
		desktop={{ width: 182, height: 246, right: 72, bottom: -14 }}
	>
		<div class="text">
			<h1 class="title" tabindex="-1">Change transaction PIN</h1>
			<p class="lead">
				<span class="mob">4 digits. Keep it to yourself.</span><span class="desk"
					>Your 4-digit PIN confirms withdrawals. Keep it to yourself.</span
				>
			</p>
		</div>
	</AccountHero>

	{#if done}
		<p class="notice" role="status">
			Your PIN is changed. Other signed-in devices will ask for the new PIN.
		</p>
		<div class="actions">
			<button type="button" class="primary" onclick={() => goto('/app/account')}>Done</button>
		</div>
	{:else}
		<form onsubmit={submit} novalidate>
			{#if formError}<FormAlert message={formError} />{/if}
			{#key attempt}
				<div class="card">
					<PinRow
						id="currentPin"
						name="currentPin"
						label="Current PIN"
						error={errors.currentPin}
						autofocus
					/>
					<PinRow id="pin" name="pin" label="New PIN" error={errors.pin} />
					<PinRow
						id="pinConfirm"
						name="pinConfirm"
						label="Confirm new PIN"
						error={errors.pinConfirm}
					/>
				</div>
			{/key}
			<div class="actions">
				<button
					type="submit"
					class="primary"
					disabled={busy || !shell.online}
					aria-busy={busy ? 'true' : undefined}>Save new PIN</button
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
		padding: 8px 0 40px;
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

	.notice,
	.forgot {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.forgot a {
		color: inherit;
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
