<!--
	Wizard, after the install step · turn on notifications (Blueprint 42; Paper
	"Push notifications v13" PN01; on computers the same words in the IA03
	layout). Shown only where push can work and hasn't been answered: anywhere
	else (iPhone Safari before the app is installed, an in-app browser, an
	answer already given) it moves on by itself. "Not now" always does.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import { onMount } from 'svelte';
	import Bell from '@lucide/svelte/icons/bell';
	import { enablePush, permission, pushSupport } from '#lib/client/push.js';
	import { installDeviceFor, type InstallDevice } from '#lib/install.js';
	import { deviceNoun } from '#lib/push.js';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import NotificationArt from '#lib/ui/onboarding/NotificationArt.svelte';
	import WizardProgress from '#lib/ui/onboarding/WizardProgress.svelte';
	import { useStageArt } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();

	let form: HTMLFormElement | undefined = $state();
	let measured = $state<InstallDevice | null>(null);
	let asking = $state(false);
	let leaving = $state(false);

	const device = $derived(measured ?? data.device);

	useStageArt(art);

	const leave = () => {
		if (leaving) return;
		leaving = true;
		form?.requestSubmit();
	};

	onMount(() => {
		measured = installDeviceFor(navigator.userAgent, navigator.maxTouchPoints);
		if (pushSupport() !== 'supported') return leave();
		const answer = permission();
		if (answer === 'denied') return leave();
		// Allowed before (another person, or turned on elsewhere): just save it.
		if (answer === 'granted')
			void enablePush(data.uid)
				.catch(() => null)
				.finally(leave);
	});

	async function turnOn() {
		asking = true;
		try {
			await enablePush(data.uid);
		} catch {
			// The switch in Profile & security can try again.
		} finally {
			asking = false;
			leave();
		}
	}
</script>

{#snippet art()}
	<NotificationArt />
{/snippet}

<svelte:head><title>Notifications · Elivate Wallet</title></svelte:head>

<WizardProgress step={data.total} total={data.total} />
<AuthHeading
	eyebrow="One last thing"
	title="Know the moment money moves"
	lead={`Get a notification on ${deviceNoun(device)} when money comes in, a withdrawal moves, or something needs you.`}
/>

<form method="POST" bind:this={form} use:enhance>
	<PrimaryButton
		label="Turn on notifications"
		icon={Bell}
		busy={asking || leaving}
		onclick={turnOn}
	/>
	<button class="later" type="submit" disabled={leaving || asking}>Not now</button>
</form>

<style>
	form {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.later {
		align-self: center;
		min-height: var(--hit-min);
		padding: 0 16px;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
		cursor: pointer;
	}

	.later:disabled {
		opacity: var(--opacity-disabled);
		cursor: default;
	}
</style>
