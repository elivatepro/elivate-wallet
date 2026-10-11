<!--
	Slice 28, Paper "PIN unlock v7" PU01 (mobile sheet), PU02 (wrong PIN) and
	PU03 (desktop card): the PIN the session owes, asked in place. Behind it is
	an outline of the app with no names or amounts (the real page is unmounted
	while locked, #lib/client/pin-lock). It cannot be dismissed; it unlocks on
	the 4th digit. The backend counts the tries; after the last one it is the
	PIN locked page (/pin/locked), as on /pin.
-->
<script lang="ts">
	import { onMount } from 'svelte';
	import { Effect, Exit } from 'effect';
	import { AccountRoutes, UnlockResult } from '#lib/contract/account.js';
	import { sendAccountCommand } from '#lib/client/api.js';
	import { failureOf } from '#lib/client/account.js';
	import { GATE_PATHS, gatePath, SIGN_IN_PATH, withNext } from '#lib/gate.js';

	let {
		firstName,
		onUnlocked,
		onSignOut
	}: {
		firstName: string | null;
		onUnlocked: () => void;
		onSignOut: () => void;
	} = $props();

	let value = $state('');
	let focused = $state(false);
	let busy = $state(false);
	let error = $state<string | null>(null);
	let input: HTMLInputElement | undefined = $state();

	onMount(() => input?.focus());

	const here = () => window.location.pathname + window.location.search;

	async function submit(pin: string) {
		busy = true;
		error = null;
		// Never retried: each try counts (Blueprint 01 B4).
		const exit = await Effect.runPromiseExit(
			sendAccountCommand(AccountRoutes.unlock.path, 'POST', { pin }, UnlockResult)
		);
		busy = false;
		// The real input too: it still holds the four digits (maxlength would block a retry).
		value = '';
		if (input) input.value = '';
		if (Exit.isSuccess(exit)) {
			if (exit.value.gate === 'ready') return onUnlocked();
			if (exit.value.gate === 'profile_required') {
				return window.location.assign(gatePath('profile_required', here()));
			}
			return window.location.assign(GATE_PATHS[exit.value.gate]);
		}
		const failure = failureOf(exit);
		if (failure?._tag === 'TransportError' && failure.status === 401) {
			return window.location.assign(withNext(SIGN_IN_PATH, here()));
		}
		if (failure?._tag === 'BackendError') {
			if (failure.code === 'pin_locked') return window.location.assign(GATE_PATHS.pin_locked);
			if (failure.code === 'pin_incorrect') {
				const left = Number(failure.details.attemptsRemaining);
				error = Number.isInteger(left)
					? `Wrong PIN. ${left} ${left === 1 ? 'try' : 'tries'} left.`
					: 'Wrong PIN.';
			} else if (failure.code === 'validation_error') {
				error = 'Enter your 4-digit PIN.';
			} else {
				error = failure.message;
			}
		} else {
			error = 'Couldn’t reach Elivate. Check your connection and try again.';
		}
		input?.focus();
	}

	function onInput(event: Event) {
		const target = event.currentTarget as HTMLInputElement;
		value = target.value.replace(/[^0-9]/g, '').slice(0, 4);
		target.value = value;
		if (value.length > 0) error = null;
		if (value.length === 4 && !busy) void submit(value);
	}
</script>

<div class="locked" aria-hidden="true">
	<div class="outline-side">
		<span class="bone b-tile"></span>
		{#each [0, 1, 2, 3, 4, 5] as row (row)}<span class="bone b-line"></span>{/each}
	</div>
	<div class="outline-main">
		<div class="outline-bar">
			<span class="bone b-tile"></span>
			<span class="bone b-title"></span>
			<span class="bone b-dot"></span>
		</div>
		<span class="bone b-heading"></span>
		<span class="bone b-hero"></span>
		<div class="outline-row">
			{#each [0, 1, 2] as stat (stat)}<span class="bone b-stat"></span>{/each}
		</div>
		<span class="bone b-block"></span>
	</div>
	<span class="outline-pill"></span>
</div>
<div class="scrim" aria-hidden="true"></div>

<div class="sheet" role="dialog" aria-modal="true" aria-labelledby="unlock-title">
	<div class="heading">
		<h1 id="unlock-title">Enter your PIN</h1>
		<p>
			{firstName ? `Welcome back, ${firstName}.` : 'Welcome back.'} Your wallet is locked.
		</p>
	</div>

	<div class="pin" class:invalid={!!error} class:busy>
		<label class="visually-hidden" for="unlock-pin">PIN</label>
		<input
			bind:this={input}
			id="unlock-pin"
			type="password"
			inputmode="numeric"
			autocomplete="off"
			maxlength="4"
			disabled={busy}
			aria-invalid={error ? 'true' : undefined}
			aria-describedby={error ? 'unlock-error' : undefined}
			oninput={onInput}
			onfocus={() => (focused = true)}
			onblur={() => (focused = false)}
		/>
		<div class="cells" aria-hidden="true">
			{#each [0, 1, 2, 3] as index (index)}
				<div class="cell" class:active={focused && index === Math.min(value.length, 3)}>
					{#if index < value.length}
						<span class="dot">•</span>
					{:else if focused && index === value.length}
						<span class="caret"></span>
					{/if}
				</div>
			{/each}
		</div>
	</div>
	<p class="error" id="unlock-error" role="alert">{error ?? ''}</p>

	<div class="links">
		<a class="forgot" href={withNext('/pin/forgot', '/app')}>Forgot PIN?</a>
		<button type="button" class="sign-out" onclick={onSignOut}>Sign out</button>
	</div>
</div>

<style>
	/* The outline behind: shapes only, never data. */
	.locked {
		position: fixed;
		inset: 0;
		display: flex;
		gap: 32px;
		padding: 16px 20px;
		background: var(--color-canvas);
		overflow: hidden;
	}

	.outline-side {
		display: none;
		flex-direction: column;
		gap: 18px;
		width: 216px;
		padding-top: 8px;
	}

	.outline-main {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 20px;
		max-width: 1100px;
	}

	.outline-bar,
	.outline-row {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	.bone {
		display: block;
		border-radius: var(--radius-12);
		background: var(--color-raised);
	}

	.b-tile {
		width: 36px;
		height: 36px;
	}

	.b-title {
		width: 140px;
		height: 16px;
	}

	.b-dot {
		margin-left: auto;
		width: 36px;
		height: 36px;
		border-radius: var(--radius-pill);
	}

	.b-line {
		width: 70%;
		height: 14px;
	}

	.b-heading {
		width: 60%;
		height: 32px;
	}

	.b-hero {
		height: 160px;
		border-radius: var(--radius-24);
		background: linear-gradient(
			100deg,
			var(--color-raised) 55%,
			color-mix(in oklab, var(--color-accent) 30%, var(--color-raised))
		);
	}

	.b-stat {
		flex: 1;
		height: 80px;
		border-radius: var(--radius-16);
	}

	.b-block {
		height: 200px;
		border-radius: var(--radius-16);
	}

	.outline-pill {
		position: absolute;
		left: 24px;
		right: 24px;
		bottom: 24px;
		height: 64px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
	}

	.scrim {
		position: fixed;
		inset: 0;
		background: color-mix(in oklab, var(--color-canvas) 55%, transparent);
		backdrop-filter: blur(14px);
		-webkit-backdrop-filter: blur(14px);
	}

	/* PU01: a bottom sheet. */
	.sheet {
		position: fixed;
		left: 0;
		right: 0;
		bottom: 0;
		display: flex;
		flex-direction: column;
		gap: 24px;
		padding: 32px 24px calc(28px + env(safe-area-inset-bottom));
		border-top: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 28px 28px 0 0;
		background:
			radial-gradient(60% 45% at 50% 0%, var(--color-accent-wash) 0%, transparent 100%),
			var(--color-surface);
		box-shadow: 0 -24px 64px rgb(0 0 0 / 0.55);
		animation: rise 220ms ease-out;
	}

	.heading {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 8px;
		text-align: center;
	}

	h1 {
		color: var(--color-text);
		font-size: 28px;
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.03em;
		line-height: 34px;
	}

	.heading p {
		color: var(--color-muted);
		font-size: var(--text-16);
		line-height: var(--leading-24);
	}

	.pin {
		position: relative;
		align-self: center;
	}

	input {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 64px;
		opacity: 0;
		cursor: text;
		z-index: 1;
	}

	.cells {
		display: flex;
		gap: 10px;
	}

	.cell {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 64px;
		height: 64px;
		border-radius: 14px;
		border: 1px solid var(--auth-field-border);
		background: var(--auth-field-bg);
	}

	.invalid .cell {
		border-color: color-mix(in oklab, var(--color-danger) 60%, transparent);
	}

	.cell.active {
		border-color: var(--color-accent);
		box-shadow: 0 0 0 3px color-mix(in oklab, var(--color-accent) 20%, transparent);
	}

	.invalid .cell.active {
		border-color: var(--color-danger);
		box-shadow: 0 0 0 3px color-mix(in oklab, var(--color-danger) 15%, transparent);
	}

	.busy .cell {
		opacity: 0.6;
	}

	.dot {
		color: var(--color-text);
		font-size: 30px;
		font-weight: var(--font-weight-semibold);
		line-height: 30px;
	}

	.caret {
		width: 2px;
		height: 24px;
		background: var(--color-accent);
		animation: blink 1s steps(1) infinite;
	}

	.error {
		min-height: 20px;
		margin-top: -12px;
		color: var(--color-danger);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
		text-align: center;
	}

	.links {
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding: 0 8px;
	}

	.forgot,
	.sign-out {
		min-height: var(--hit-min);
		display: inline-flex;
		align-items: center;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	.forgot {
		color: var(--color-text);
		text-decoration: underline 1px var(--auth-link-underline);
		text-underline-offset: 4px;
	}

	.sign-out {
		color: var(--color-muted);
		background: none;
		border: 0;
		cursor: pointer;
	}

	/* PU03: a centred card on desktop, the outline gets its sidebar. */
	@media (min-width: 1024px) {
		.locked {
			padding: 24px;
		}

		.outline-side {
			display: flex;
		}

		.outline-pill {
			display: none;
		}

		.sheet {
			left: 50%;
			top: 50%;
			right: auto;
			bottom: auto;
			width: 440px;
			padding: 40px 40px 36px;
			border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
			border-radius: 28px;
			box-shadow: 0 32px 80px rgb(0 0 0 / 0.6);
			translate: -50% -50%;
			animation: fade 200ms ease-out;
		}
	}

	@keyframes rise {
		from {
			translate: 0 40px;
			opacity: 0;
		}
	}

	@keyframes fade {
		from {
			opacity: 0;
		}
	}

	@keyframes blink {
		50% {
			opacity: 0;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.sheet,
		.caret {
			animation: none;
		}
	}
</style>
