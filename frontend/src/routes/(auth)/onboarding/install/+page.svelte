<!--
	Wizard last step · install the app (Blueprint 35). Paper "Install app v9":
	IA01 Android (the browser's install prompt), IA02 iPhone/iPad Safari (three
	taps), IA03 computer (prompt plus a QR code for the phone). Opened as the
	app already, it moves on by itself; "Not now" always does.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import { onMount } from 'svelte';
	import Download from '@lucide/svelte/icons/download';
	import Share from '@lucide/svelte/icons/share';
	import SquarePlus from '@lucide/svelte/icons/square-plus';
	import {
		installPrompt,
		promptInstall,
		runningInstalled
	} from '#lib/client/install-prompt.svelte.js';
	import { installDeviceFor, type InstallDevice } from '#lib/install.js';
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import InstallArt from '#lib/ui/onboarding/InstallArt.svelte';
	import WizardProgress from '#lib/ui/onboarding/WizardProgress.svelte';
	import { useStageArt } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();

	let form: HTMLFormElement | undefined = $state();
	/** The browser's own answer (an iPad says "Mac" to the server). */
	let measured = $state<InstallDevice | null>(null);
	/**
	 * The install prompt didn't come or was dismissed: this browser can't
	 * install, already has, or won't offer it again on this page.
	 */
	let gaveUp = $state(false);
	let prompting = $state(false);
	let leaving = $state(false);

	const device = $derived(measured ?? data.device);
	const desktop = $derived(device === 'desktop' || device === 'mac-safari');
	const usesPrompt = $derived(device === 'android' || device === 'desktop');
	const cannot = $derived(device === 'in-app' || (usesPrompt && gaveUp && !installPrompt.event));

	useStageArt(art);

	const leave = () => {
		if (leaving) return;
		leaving = true;
		form?.requestSubmit();
	};

	onMount(() => {
		measured = installDeviceFor(navigator.userAgent, navigator.maxTouchPoints);
		if (runningInstalled()) return leave();
		const timer = setTimeout(() => (gaveUp = true), 3000);
		return () => clearTimeout(timer);
	});

	$effect(() => {
		if (installPrompt.installed) leave();
	});

	async function install() {
		prompting = true;
		try {
			if (await promptInstall()) leave();
		} finally {
			prompting = false;
		}
	}

	const heading = $derived.by(() => {
		if (device === 'in-app') {
			return {
				title: 'Open in your browser to install',
				lead: 'Apps can’t be installed from inside another app. Open this page in Chrome or Safari, then install it there.'
			};
		}
		if (cannot) {
			return {
				title: desktop ? 'Install Elivate Wallet' : 'Put Elivate Wallet on your home screen',
				lead: 'Your browser isn’t offering to install it right now. Look for Install or Add to Home screen in its menu, or continue for now.'
			};
		}
		if (device === 'ios') {
			return {
				title: 'Add Elivate Wallet to your home screen',
				lead: 'Safari does this in three taps.'
			};
		}
		if (device === 'mac-safari') {
			return {
				title: 'Install Elivate Wallet',
				lead: 'In Safari, choose File, then Add to Dock. It opens in its own window.'
			};
		}
		if (desktop) {
			return {
				title: 'Install Elivate Wallet',
				lead: 'It opens in its own window, straight from your dock or Start menu.'
			};
		}
		return {
			title: 'Put Elivate Wallet on your home screen',
			lead: 'Open your wallet in one tap, full screen, like any other app.'
		};
	});
</script>

{#snippet art()}
	<InstallArt {desktop} />
{/snippet}

<svelte:head><title>Install the app · Elivate Wallet</title></svelte:head>

<WizardProgress step={data.total} total={data.total} />
<AuthHeading eyebrow="Last step" title={heading.title} lead={heading.lead} />

{#if device === 'ios' && !cannot}
	<ol class="steps">
		<li>
			<span class="num">1</span><span class="step">Tap Share in Safari</span>
			<Share size={20} strokeWidth={1.8} class="share" aria-hidden="true" />
		</li>
		<li>
			<span class="num">2</span><span class="step">Choose Add to Home Screen</span>
			<SquarePlus size={20} strokeWidth={1.8} aria-hidden="true" />
		</li>
		<li>
			<span class="num">3</span><span class="step">Tap Add, then open Elivate Wallet</span>
			<img class="mini" src="/icons/icon-192.png" alt="" width="24" height="24" />
		</li>
	</ol>
{/if}

{#if data.qr && desktop}
	<div class="phone">
		<svg
			class="qr"
			viewBox="0 0 {data.qr.size} {data.qr.size}"
			shape-rendering="crispEdges"
			role="img"
			aria-label="QR code that opens Elivate Wallet on your phone"
		>
			<rect width={data.qr.size} height={data.qr.size} fill="#ffffff" />
			<path d={data.qr.d} fill="#14100e" />
		</svg>
		<div class="phone-text">
			<p class="phone-title">Want it on your phone too?</p>
			<p class="phone-lead">
				Point your phone’s camera here to open Elivate Wallet, then install it there.
			</p>
		</div>
	</div>
{/if}

<form method="POST" bind:this={form} use:enhance>
	{#if usesPrompt && !cannot}
		<PrimaryButton
			label="Install the app"
			icon={Download}
			busy={prompting || leaving || !installPrompt.event}
			onclick={install}
		/>
		<button class="later" type="submit" disabled={leaving}>Not now</button>
	{:else if cannot}
		<PrimaryButton label="Continue" busy={leaving} />
	{:else}
		<PrimaryButton label="I’ve added it" busy={leaving} />
		<button class="later" type="submit" disabled={leaving}>Not now</button>
	{/if}
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

	.steps {
		margin: 0;
		padding: 0;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: var(--radius-16);
		background: color-mix(in oklab, var(--color-surface) 80%, transparent);
		list-style: none;
	}

	.steps li {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 56px;
		padding: 8px 16px;
	}

	.steps li + li {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.num {
		width: 24px;
		flex-shrink: 0;
		color: var(--color-accent-text);
		font-family: var(--font-mono);
		font-size: 13px;
		line-height: var(--leading-16);
	}

	.step {
		flex: 1;
		color: var(--color-text);
		font-size: 15px;
		line-height: var(--leading-20);
	}

	.steps :global(.share) {
		flex-shrink: 0;
		color: var(--color-info);
	}

	.mini {
		flex-shrink: 0;
		width: 24px;
		height: 24px;
		border-radius: 7px;
	}

	.phone {
		display: flex;
		align-items: center;
		gap: 16px;
		padding: 12px 16px 12px 12px;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: var(--radius-16);
		background: color-mix(in oklab, var(--color-surface) 80%, transparent);
	}

	.qr {
		flex-shrink: 0;
		width: 96px;
		height: 96px;
		border-radius: 10px;
	}

	.phone-text {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	.phone-title {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	.phone-lead {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}
</style>
