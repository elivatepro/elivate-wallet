<!--
	Signed-in shell placeholder (M1). Mobile: top bar + bottom navigation;
	desktop: capability-derived sidebar (P-06). Offline/stale banner and the
	update prompt follow decision 36a. No financial data exists yet, so nothing
	here shows or invents balances.
-->
<script lang="ts">
	import { onMount, setContext } from 'svelte';
	import { updated } from '$app/state';
	import { DropdownMenu, Popover } from 'bits-ui';
	import Bell from '@lucide/svelte/icons/bell';
	import Home from '@lucide/svelte/icons/house';
	import CircleUser from '@lucide/svelte/icons/circle-user-round';
	import WifiOff from '@lucide/svelte/icons/wifi-off';
	import RefreshCw from '@lucide/svelte/icons/refresh-cw';
	import { purgeAllDeviceData, staleLabel } from '#lib/client/device-cache.js';
	import { Shell } from '#lib/client/shell.svelte.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import { parseTheme, THEMES, type Theme } from '#lib/theme.js';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();

	const shell = new Shell();
	setContext('shell', shell);

	let signOutForm: HTMLFormElement | undefined = $state();

	onMount(() => {
		// The prerendered shell ships with the default theme; follow the cookie.
		theme = parseTheme(document.cookie.match(/(?:^|; )ew_theme=([^;]+)/)?.[1]);
		document.documentElement.dataset.theme = theme;
		return shell.start();
	});

	const summary = $derived(
		shell.state.kind === 'ready' || shell.state.kind === 'offline' ? shell.state.summary : null
	);

	async function reloadForUpdate() {
		const registration = await navigator.serviceWorker?.getRegistration();
		registration?.waiting?.postMessage({ type: 'SKIP_WAITING' });
		window.location.reload();
	}

	let theme: Theme = $state('dark');
	const themeLabels: Record<Theme, string> = { dark: 'Dark', light: 'Light', system: 'System' };

	// Same non-sensitive cookie the server-rendered pages read (W-01 theme choice).
	function setTheme(value: string) {
		theme = parseTheme(value);
		document.documentElement.dataset.theme = theme;
		const secure = location.protocol === 'https:' ? '; Secure' : '';
		document.cookie = `ew_theme=${theme}; Path=/; Max-Age=31536000; SameSite=Lax${secure}`;
	}

	function signOut() {
		purgeAllDeviceData();
		signOutForm?.requestSubmit();
	}
</script>

<svelte:head><title>Elivate Wallet</title></svelte:head>

<form method="POST" action="/sign-out" bind:this={signOutForm} hidden></form>

<div class="shell">
	<aside class="sidebar" aria-label="Main">
		<a class="brand" href="/app">
			<img src="/icons/mark.svg" alt="" width="32" height="32" />
			<span>Elivate Wallet</span>
		</a>
		<nav>
			<a class="nav-item" href="/app" aria-current="page">
				<Home size={20} strokeWidth={1.6} aria-hidden="true" /><span>Home</span>
			</a>
		</nav>
	</aside>

	<div class="main">
		<header class="topbar">
			<a class="brand mobile-only" href="/app" aria-label="Elivate Wallet home">
				<img src="/icons/mark.svg" alt="" width="28" height="28" />
			</a>
			<div class="workspace">
				{#if summary}
					<span class="tenant">{summary.tenantName}</span>
					<span class="role"
						>{ROLE_LABELS[summary.role]}{summary.officeName ? ` · ${summary.officeName}` : ''}</span
					>
				{:else if shell.state.kind === 'loading'}
					<span class="role" aria-busy="true">Loading…</span>
				{/if}
			</div>
			<div class="tools">
				<Popover.Root>
					<Popover.Trigger class="icon-button" aria-label="Notifications">
						<Bell size={20} strokeWidth={1.6} aria-hidden="true" />
					</Popover.Trigger>
					<Popover.Portal>
						<Popover.Content class="popover" sideOffset={8} align="end">
							<p>No notifications yet.</p>
						</Popover.Content>
					</Popover.Portal>
				</Popover.Root>
				<DropdownMenu.Root>
					<DropdownMenu.Trigger class="icon-button" aria-label="Account">
						<CircleUser size={20} strokeWidth={1.6} aria-hidden="true" />
					</DropdownMenu.Trigger>
					<DropdownMenu.Portal>
						<DropdownMenu.Content class="menu" sideOffset={8} align="end">
							{#if shell.state.kind === 'ready'}
								<div class="menu-label">{shell.state.view.state.uid}</div>
							{/if}
							<DropdownMenu.Item
								class="menu-item"
								onSelect={() => window.location.assign('/workspaces?switch')}
							>
								Switch workspace
							</DropdownMenu.Item>
							<DropdownMenu.CheckboxItem
								class="menu-item"
								checked={shell.hideAmounts}
								onCheckedChange={(value) => shell.setHideAmounts(value)}
							>
								{#snippet children({ checked })}
									<span>Hide amounts</span><span class="check">{checked ? 'On' : 'Off'}</span>
								{/snippet}
							</DropdownMenu.CheckboxItem>
							<DropdownMenu.RadioGroup value={theme} onValueChange={setTheme} aria-label="Theme">
								{#each THEMES as option (option)}
									<DropdownMenu.RadioItem class="menu-item" value={option}>
										{#snippet children({ checked })}
											<span>{themeLabels[option]} theme</span><span class="check"
												>{checked ? 'On' : ''}</span
											>
										{/snippet}
									</DropdownMenu.RadioItem>
								{/each}
							</DropdownMenu.RadioGroup>
							<DropdownMenu.Item class="menu-item" disabled={!shell.online} onSelect={signOut}>
								Sign out
							</DropdownMenu.Item>
						</DropdownMenu.Content>
					</DropdownMenu.Portal>
				</DropdownMenu.Root>
			</div>
		</header>

		{#if updated.current}
			<div class="banner" role="status">
				<span>A new version of Elivate Wallet is ready.</span>
				<button type="button" onclick={reloadForUpdate}
					><RefreshCw size={16} aria-hidden="true" />Reload</button
				>
			</div>
		{/if}

		{#if shell.state.kind === 'offline'}
			<div class="banner offline" role="status">
				<WifiOff size={16} aria-hidden="true" />
				<span>
					{shell.state.savedAt ? staleLabel(shell.state.savedAt, true) : 'You’re offline'}. Actions
					are unavailable until you reconnect.
				</span>
			</div>
		{/if}

		<main class="content" id="main">
			{#if shell.state.kind === 'error'}
				<section class="state" role="alert">
					<h1>We couldn’t load your workspace</h1>
					<p>{shell.state.message}</p>
					{#if shell.state.reference}<p class="ref">Reference {shell.state.reference}</p>{/if}
					<button type="button" class="retry" onclick={() => shell.load()}>Try again</button>
				</section>
			{:else if shell.state.kind === 'offline' && !shell.state.summary}
				<section class="state">
					<h1>You’re offline</h1>
					<p>Wallet data needs a connection the first time.</p>
				</section>
			{:else}
				{@render children()}
			{/if}
		</main>

		<nav class="bottom-nav" aria-label="Main">
			<a class="nav-item" href="/app" aria-current="page">
				<Home size={22} strokeWidth={1.6} aria-hidden="true" /><span>Home</span>
			</a>
		</nav>
	</div>
</div>

<style>
	.shell {
		display: flex;
		min-height: 100dvh;
		background: var(--color-canvas);
	}

	.sidebar {
		display: none;
	}

	.main {
		display: flex;
		flex: 1;
		flex-direction: column;
		min-width: 0;
		padding-bottom: calc(72px + env(safe-area-inset-bottom));
	}

	.topbar {
		position: sticky;
		top: 0;
		z-index: 2;
		display: flex;
		align-items: center;
		gap: 12px;
		padding: calc(8px + env(safe-area-inset-top)) 12px 8px 16px;
		border-bottom: 1px solid var(--color-border);
		background: color-mix(in oklab, var(--color-canvas) 92%, transparent);
		backdrop-filter: blur(12px);
	}

	.brand {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: var(--hit-min);
		color: var(--color-text);
		text-decoration: none;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.01em;
	}

	.workspace {
		display: flex;
		flex: 1;
		flex-direction: column;
		min-width: 0;
	}

	.tenant {
		overflow: hidden;
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-20);
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.role {
		overflow: hidden;
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.tools {
		display: flex;
		gap: 4px;
	}

	:global(.icon-button) {
		display: flex;
		align-items: center;
		justify-content: center;
		width: var(--hit-min);
		height: var(--hit-min);
		border: 0;
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-text);
		cursor: pointer;
	}

	:global(.icon-button:hover) {
		background: var(--color-raised);
	}

	:global(.popover),
	:global(.menu) {
		z-index: 10;
		min-width: 220px;
		padding: 8px;
		border-radius: var(--radius-12);
		border: 1px solid var(--color-border);
		background: var(--color-surface);
		color: var(--color-text);
		box-shadow: #00000066 0px 16px 40px -12px;
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	:global(.popover p) {
		padding: 8px;
		color: var(--color-muted);
	}

	:global(.menu-label) {
		padding: 8px 12px;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		letter-spacing: var(--tracking-label);
	}

	:global(.menu-item) {
		display: flex;
		align-items: center;
		justify-content: space-between;
		min-height: var(--hit-min);
		padding: 0 12px;
		border-radius: var(--radius-8);
		cursor: pointer;
		outline: none;
	}

	:global(.menu-item[data-highlighted]) {
		background: var(--color-raised);
	}

	:global(.menu-item[data-disabled]) {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	:global(.check) {
		color: var(--color-muted);
	}

	.banner {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 8px 12px;
		margin: 12px 16px 0;
		padding: 10px 14px;
		border-radius: var(--radius-12);
		border: 1px solid color-mix(in oklab, var(--color-info) 45%, transparent);
		background: color-mix(in oklab, var(--color-info) 12%, transparent);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.banner.offline {
		border-color: color-mix(in oklab, var(--color-warning) 45%, transparent);
		background: color-mix(in oklab, var(--color-warning) 12%, transparent);
	}

	.banner button {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		min-height: var(--hit-min);
		padding: 0 14px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: var(--color-surface);
		cursor: pointer;
	}

	.content {
		flex: 1;
		width: 100%;
		max-width: var(--container-content);
		margin: 0 auto;
		padding: 24px 16px;
	}

	.state {
		display: flex;
		flex-direction: column;
		gap: 8px;
		max-width: 460px;
	}

	.state h1 {
		font-size: var(--text-24);
		line-height: var(--leading-32);
		letter-spacing: var(--tracking-display);
	}

	.state p {
		color: var(--color-muted);
	}

	.ref {
		font-size: var(--text-12);
	}

	.retry {
		align-self: flex-start;
		min-height: var(--hit-min);
		margin-top: 8px;
		padding: 0 18px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: var(--color-surface);
		cursor: pointer;
	}

	.bottom-nav {
		position: fixed;
		left: 0;
		right: 0;
		bottom: 0;
		z-index: 2;
		display: flex;
		justify-content: space-around;
		padding: 6px 8px calc(6px + env(safe-area-inset-bottom));
		border-top: 1px solid var(--color-border);
		background: var(--color-surface);
	}

	.nav-item {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 2px;
		min-width: 64px;
		min-height: 52px;
		border-radius: var(--radius-12);
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
		text-decoration: none;
	}

	.nav-item[aria-current='page'] {
		color: var(--color-text);
	}

	@media (min-width: 1024px) {
		.sidebar {
			position: sticky;
			top: 0;
			display: flex;
			flex-direction: column;
			gap: 24px;
			width: var(--container-sidebar);
			height: 100dvh;
			padding: 24px 16px;
			border-right: 1px solid var(--color-border);
			background: var(--color-surface);
		}

		.sidebar .nav-item {
			flex-direction: row;
			justify-content: flex-start;
			gap: 12px;
			min-height: var(--hit-min);
			padding: 0 12px;
			font-size: var(--text-14);
			line-height: var(--leading-20);
		}

		.sidebar .nav-item[aria-current='page'] {
			background: var(--color-raised);
		}

		.mobile-only,
		.bottom-nav {
			display: none;
		}

		.main {
			padding-bottom: 0;
		}

		.topbar {
			padding: 12px 24px;
		}

		.content {
			padding: 32px 24px;
		}
	}
</style>
