<!--
	iOS "Add to Home Screen" hint, Paper "App — Screens v3" H08 (decision 36a).
	Shown once in iOS Safari when the app is not already installed; "Got it"
	remembers the dismissal on this device. Blueprint 43: a drag down dismisses
	it too (always a sheet, iPad included).
-->
<script lang="ts">
	import { onMount } from 'svelte';
	import Share from '@lucide/svelte/icons/share';
	import SquarePlus from '@lucide/svelte/icons/square-plus';
	import { sheetDrag } from '#lib/ui/sheet-drag.js';

	const DISMISSED_KEY = 'ew:pref:install-hint-dismissed';

	let open = $state(false);
	let dialog: HTMLDialogElement | undefined = $state();

	onMount(() => {
		const ios = /iPad|iPhone|iPod/.test(navigator.userAgent);
		const standalone =
			window.matchMedia('(display-mode: standalone)').matches ||
			(navigator as Navigator & { standalone?: boolean }).standalone === true;
		let dismissed: boolean;
		try {
			dismissed = localStorage.getItem(DISMISSED_KEY) === '1';
		} catch {
			dismissed = true; // storage blocked: don't nag every visit
		}
		if (ios && !standalone && !dismissed) open = true;
	});

	$effect(() => {
		if (open && dialog && !dialog.open) dialog.showModal();
	});

	function dismiss() {
		open = false;
		dialog?.close();
		try {
			localStorage.setItem(DISMISSED_KEY, '1');
		} catch {
			// best-effort preference
		}
	}
</script>

{#if open}
	<dialog
		class="sheet"
		bind:this={dialog}
		aria-labelledby="install-title"
		onclose={dismiss}
		onclick={(event) => {
			if (event.target === dialog) dismiss();
		}}
		{@attach sheetDrag({ close: dismiss, active: () => true })}
	>
		<div class="inner">
			<span class="grabber" aria-hidden="true" data-sheet-grab></span>
			<div class="head" data-sheet-grab>
				<span class="app-tile" aria-hidden="true"
					><img src="/icons/mark.svg" alt="" width="30" height="30" /></span
				>
				<div class="head-text">
					<h2 id="install-title">Add to Home Screen</h2>
					<p>Open Elivate Wallet like an app.</p>
				</div>
			</div>
			<ol class="steps">
				<li>
					<span class="num">1</span><span class="step">Tap Share</span>
					<Share size={20} strokeWidth={1.8} class="share" aria-hidden="true" />
				</li>
				<li>
					<span class="num">2</span><span class="step">Add to Home Screen</span>
					<SquarePlus size={20} strokeWidth={1.8} aria-hidden="true" />
				</li>
			</ol>
			<button type="button" class="got-it" onclick={dismiss}>Got it</button>
		</div>
	</dialog>
{/if}

<style>
	.sheet {
		position: fixed;
		inset: auto 0 0 0;
		width: 100%;
		max-width: 100%;
		margin: 0;
		padding: 0;
		border: 0;
		border-top: 1px solid var(--color-border);
		border-radius: 24px 24px 0 0;
		background: var(--color-surface);
		color: var(--color-text);
	}

	.sheet::backdrop {
		background: #0c0e0fad;
	}

	.inner {
		display: flex;
		flex-direction: column;
		gap: 20px;
		padding: 12px 20px calc(34px + env(safe-area-inset-bottom));
	}

	.grabber {
		align-self: center;
		width: 36px;
		height: 4px;
		border-radius: var(--radius-pill);
		background: #ffffff33;
	}

	.head {
		display: flex;
		align-items: center;
		gap: 14px;
	}

	.app-tile {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 56px;
		height: 56px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: var(--color-canvas);
	}

	.app-tile img {
		width: 30px;
		height: 30px;
	}

	.head-text {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	h2 {
		font-size: var(--text-20);
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.02em;
		line-height: 26px;
	}

	.head-text p {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.steps {
		margin: 0;
		padding: 0;
		border-radius: var(--radius-16);
		background: var(--color-raised);
		list-style: none;
	}

	.steps li {
		display: flex;
		align-items: center;
		gap: 12px;
		height: 56px;
		padding: 0 16px;
	}

	.steps li + li {
		border-top: 1px solid #ffffff0a;
	}

	.num {
		width: 24px;
		color: var(--color-accent-text);
		font-family: var(--font-mono);
		font-size: 13px;
		line-height: var(--leading-16);
	}

	.step {
		flex: 1;
		font-size: 15px;
		line-height: var(--leading-20);
	}

	.steps :global(.share) {
		color: var(--color-info);
	}

	.got-it {
		height: 52px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
		cursor: pointer;
	}
</style>
