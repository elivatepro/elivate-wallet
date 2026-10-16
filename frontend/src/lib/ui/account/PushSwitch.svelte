<!--
	Profile & security · Notifications (Blueprint 42; Paper "Push notifications
	v13" PN02, states PN03): one switch for this device only. Off, on, blocked
	in the device's settings, or (iPhone Safari) add Wallet to the Home Screen
	first. Left out where the browser has no push or push isn't set up.
-->
<script lang="ts">
	import { onMount } from 'svelte';
	import {
		disablePush,
		enablePush,
		permission,
		pushSupport,
		readDevicePush
	} from '#lib/client/push.js';
	import { installDeviceFor } from '#lib/install.js';
	import { deviceNoun, switchStateFor, type SwitchState } from '#lib/push.js';

	let {
		uid,
		hideAmounts,
		disabled = false
	}: { uid: string | null; hideAmounts: boolean; disabled?: boolean } = $props();

	let view = $state<SwitchState>('hidden');
	let noun = $state('this phone');
	let busy = $state(false);
	let failed = $state(false);

	async function refresh() {
		const support = pushSupport();
		if (support !== 'supported') {
			view = switchStateFor(support, null, false, true);
			return;
		}
		try {
			const device = await readDevicePush();
			view = switchStateFor(support, permission(), device.on, device.configured);
		} catch {
			view = 'hidden';
		}
	}

	onMount(() => {
		noun = deviceNoun(installDeviceFor(navigator.userAgent, navigator.maxTouchPoints));
	});

	// Read once the shell knows who is signed in: it has queued the quiet
	// re-save by then (resumePush), and the read waits for it.
	let readFor: string | null = null;
	$effect(() => {
		if (!uid || uid === readFor) return;
		readFor = uid;
		void refresh();
	});

	async function toggle() {
		if (busy || !uid) return;
		busy = true;
		failed = false;
		try {
			if (view === 'on') {
				await disablePush();
				view = 'off';
			} else {
				const result = await enablePush(uid, hideAmounts);
				view = result === 'on' ? 'on' : result === 'blocked' ? 'blocked' : 'off';
				failed = result === 'unavailable';
			}
		} catch {
			failed = true;
			await refresh();
		} finally {
			busy = false;
		}
	}

	const hint = $derived(
		failed
			? 'Couldn’t change it. Try again.'
			: view === 'blocked'
				? `Blocked in your ${noun === 'this phone' ? 'phone' : 'browser'}’s settings. Allow notifications for Wallet there, then come back.`
				: view === 'ios-install-first'
					? 'Add Wallet to your Home Screen first. iPhone only sends notifications to installed apps.'
					: 'Money moving and things that need you'
	);
</script>

{#if view !== 'hidden'}
	<section class="group" aria-labelledby="push-heading">
		<h2 class="eyebrow" id="push-heading">Notifications</h2>
		<div class="card">
			<div class="card-head"><h2 class="card-title">Notifications</h2></div>
			<div class="row">
				<span class="stack">
					<span class="label" id="push-label">Notifications on {noun}</span>
					<span class="hint" class:warn={view === 'blocked' || failed} id="push-hint">{hint}</span>
				</span>
				<button
					type="button"
					class="switch"
					role="switch"
					aria-checked={view === 'on'}
					aria-labelledby="push-label"
					aria-describedby="push-hint"
					aria-busy={busy}
					disabled={disabled || busy || !uid || view === 'blocked' || view === 'ios-install-first'}
					onclick={toggle}
				>
					<span class="knob"></span>
				</button>
			</div>
		</div>
	</section>
{/if}

<style>
	.group {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.eyebrow {
		padding-left: 4px;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.08em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.card {
		border: 1px solid #ffffff14;
		border-radius: 18px;
		background: var(--color-surface);
	}

	:global([data-theme='light']) .card {
		border-color: var(--color-border);
	}

	.row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		min-height: 60px;
		padding: 12px 16px;
	}

	.stack {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.label {
		color: var(--color-text);
		font-size: 15px;
		line-height: 18px;
	}

	.hint {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.hint.warn {
		color: var(--color-warning);
	}

	.switch {
		display: flex;
		align-items: center;
		flex-shrink: 0;
		width: 44px;
		height: 26px;
		padding: 3px;
		border: 0;
		border-radius: var(--radius-pill);
		background: #343a3c;
		cursor: pointer;
		transition: background-color 160ms ease;
	}

	:global([data-theme='light']) .switch {
		background: var(--color-border);
	}

	.knob {
		width: 20px;
		height: 20px;
		border-radius: var(--radius-pill);
		background: #a9b0b3;
		transition: transform 160ms ease;
	}

	.switch[aria-checked='true'] {
		background: var(--color-accent);
	}

	.switch[aria-checked='true'] .knob {
		background: #fff4ef;
		transform: translateX(18px);
	}

	.switch:disabled {
		cursor: not-allowed;
		opacity: var(--opacity-disabled);
	}

	.switch[aria-busy='true'] {
		cursor: progress;
		opacity: 1;
	}

	.switch:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 2px;
	}

	@media (prefers-reduced-motion: reduce) {
		.switch,
		.knob {
			transition: none;
		}
	}

	.card-head {
		display: none;
	}

	/* Desktop: the title sits in the card, like Profile and Security. */
	@media (min-width: 1024px) {
		.eyebrow {
			display: none;
		}

		.card {
			border-radius: var(--radius-16);
		}

		.card-head {
			display: flex;
			padding: 18px 22px;
			border-bottom: 1px solid #ffffff0f;
		}

		:global([data-theme='light']) .card-head {
			border-bottom-color: var(--color-border);
		}

		.card-title {
			color: var(--color-text);
			font-size: var(--text-16);
			font-weight: var(--font-weight-semibold);
			line-height: var(--leading-20);
		}

		.row {
			padding: 16px 22px;
		}
	}
</style>
