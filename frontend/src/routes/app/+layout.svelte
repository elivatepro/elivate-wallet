<!--
	Signed-in shell, Paper "App — Screens v3" H01–H09: desktop sidebar + top bar,
	mobile app bar + floating bottom nav, account menu (desktop) / More tab
	(mobile), notifications, offline and update banners, load-error and
	offline-empty Root heroes, iOS install hint. Only routes that exist are
	linked; nothing here shows or invents balances (W-00, decision 36a).
-->
<script lang="ts">
	import { onMount, setContext } from 'svelte';
	import { page, updated } from '$app/state';
	import { DropdownMenu, Popover } from 'bits-ui';
	import ArrowLeftRight from '@lucide/svelte/icons/arrow-left-right';
	import Bell from '@lucide/svelte/icons/bell';
	import Building from '@lucide/svelte/icons/building-2';
	import FileText from '@lucide/svelte/icons/file-text';
	import Shield from '@lucide/svelte/icons/shield';
	import Users from '@lucide/svelte/icons/users';
	import ChevronsUpDown from '@lucide/svelte/icons/chevrons-up-down';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import EyeOff from '@lucide/svelte/icons/eye-off';
	import House from '@lucide/svelte/icons/house';
	import IdCard from '@lucide/svelte/icons/id-card';
	import Landmark from '@lucide/svelte/icons/landmark';
	import MailPlus from '@lucide/svelte/icons/mail-plus';
	import PieChart from '@lucide/svelte/icons/chart-pie';
	import LogOut from '@lucide/svelte/icons/log-out';
	import RotateCw from '@lucide/svelte/icons/rotate-cw';
	import UserRound from '@lucide/svelte/icons/user-round';
	import WifiOff from '@lucide/svelte/icons/wifi-off';
	import { Appearance, THEME_LABELS } from '#lib/client/appearance.svelte.js';
	import { purgeAllDeviceData, staleLabel } from '#lib/client/device-cache.js';
	import { Shell } from '#lib/client/shell.svelte.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import InstallHint from '#lib/ui/app/InstallHint.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();

	const shell = new Shell();
	const appearance = new Appearance();
	setContext('shell', shell);
	setContext('appearance', appearance);

	let signOutForm: HTMLFormElement | undefined = $state();
	setContext('signOut', signOut);

	onMount(() => {
		appearance.start();
		return shell.start();
	});

	const summary = $derived(
		shell.state.kind === 'ready' || shell.state.kind === 'offline' ? shell.state.summary : null
	);
	const uid = $derived(shell.state.kind === 'ready' ? shell.state.view.state.uid : null);
	const person = $derived(shell.state.kind === 'ready' ? shell.state.view.profile : null);
	const path = $derived(page.url.pathname);
	/** Navigation hint only; every command is still authorized by the backend. */
	const TITLES: Record<string, string> = {
		'/app/payout-accounts': 'Payout accounts',
		'/app/invitations': 'Invitations',
		'/app/split': 'Pockets & split',
		'/app/reviews': 'NIN reviews',
		'/app/notifications': 'Notifications',
		'/app/more': 'More',
		'/app/offices': 'Offices',
		'/app/members': 'Members',
		'/app/access': 'Roles & access',
		'/app/audit': 'Audit log'
	};
	const pageTitle = $derived(
		Object.entries(TITLES).find(([prefix]) => path.startsWith(prefix))?.[1] ?? 'Home'
	);
	/** Blueprint 06 Q4 reviewers (the backend re-checks each review). */
	const reviewer = $derived(
		summary?.role === 'president_team_member' || summary?.role === 'world_team_member'
	);
	const can = (permission: string) =>
		shell.state.kind === 'ready' &&
		(shell.state.view.capabilities?.permissions ?? []).includes(permission);
	/** Org management entries (Blueprint 07); navigation hints only. */
	const president = $derived(summary?.role === 'president_team_member');
	const leads = $derived(president || can('manage_members') || can('view_managed_wallets'));
	/** Pushed pages (mobile Notifications) have their own nav bar and no tabs. */
	const pushed = $derived(path.startsWith('/app/notifications'));
	const tabMore = $derived(path.startsWith('/app/more'));
	/** Only Home needs workspace data; More and Notifications keep their controls. */
	const needsData = $derived(path === '/app');

	async function reloadForUpdate() {
		const registration = await navigator.serviceWorker?.getRegistration();
		registration?.waiting?.postMessage({ type: 'SKIP_WAITING' });
		window.location.reload();
	}

	function signOut() {
		purgeAllDeviceData();
		signOutForm?.requestSubmit();
	}

	const switchWorkspace = () => window.location.assign('/workspaces?switch');
</script>

<svelte:head><title>Elivate Wallet</title></svelte:head>

<form method="POST" action="/sign-out" bind:this={signOutForm} hidden></form>

{#snippet workspaceLabel()}
	<span class="ws-text">
		<span class="ws-name">{summary?.officeName ?? summary?.tenantName ?? ''}</span>
		{#if summary}<span class="ws-chip">{ROLE_LABELS[summary.role]}</span>{/if}
	</span>
{/snippet}

{#snippet brandTile()}
	<span class="brand-tile" aria-hidden="true"><img src="/icons/mark.svg" alt="" /></span>
{/snippet}

{#snippet avatar()}
	<UserRound size={18} strokeWidth={1.6} aria-hidden="true" />
{/snippet}

<div class="shell" class:pushed>
	<aside class="sidebar" aria-label="Main">
		<div class="switcher-block">
			<button
				type="button"
				class="switcher"
				onclick={switchWorkspace}
				aria-label={summary ? `${summary.tenantName}: switch workspace` : 'Switch workspace'}
			>
				{@render brandTile()}
				{@render workspaceLabel()}
				<span class="chev-circle" aria-hidden="true"
					><ChevronsUpDown size={14} strokeWidth={1.6} /></span
				>
			</button>
		</div>
		<nav class="side-nav">
			<a class="side-item" href="/app" aria-current={path === '/app' ? 'page' : undefined}>
				<House size={18} strokeWidth={1.5} aria-hidden="true" /><span>Home</span>
			</a>
			<a
				class="side-item"
				href="/app/payout-accounts"
				aria-current={path.startsWith('/app/payout-accounts') ? 'page' : undefined}
			>
				<Landmark size={18} strokeWidth={1.5} aria-hidden="true" /><span>Payout accounts</span>
			</a>
			{#if can('invite_members')}
				<a
					class="side-item"
					href="/app/invitations"
					aria-current={path.startsWith('/app/invitations') ? 'page' : undefined}
				>
					<MailPlus size={18} strokeWidth={1.5} aria-hidden="true" /><span>Invitations</span>
				</a>
			{/if}
			{#if reviewer}
				<a
					class="side-item"
					href="/app/reviews"
					aria-current={path.startsWith('/app/reviews') ? 'page' : undefined}
				>
					<IdCard size={18} strokeWidth={1.5} aria-hidden="true" /><span>NIN reviews</span>
				</a>
			{/if}
			<a
				class="side-item"
				href="/app/split"
				aria-current={path.startsWith('/app/split') ? 'page' : undefined}
			>
				<PieChart size={18} strokeWidth={1.5} aria-hidden="true" /><span>Pockets &amp; split</span>
			</a>
			{#if leads}
				<a
					class="side-item"
					href="/app/offices"
					aria-current={path.startsWith('/app/offices') ? 'page' : undefined}
				>
					<Building size={18} strokeWidth={1.5} aria-hidden="true" /><span>Offices</span>
				</a>
				<a
					class="side-item"
					href="/app/members"
					aria-current={path.startsWith('/app/members') ? 'page' : undefined}
				>
					<Users size={18} strokeWidth={1.5} aria-hidden="true" /><span>Members</span>
				</a>
			{/if}
			{#if president || can('manage_access_rules')}
				<a
					class="side-item"
					href="/app/access"
					aria-current={path.startsWith('/app/access') ? 'page' : undefined}
				>
					<Shield size={18} strokeWidth={1.5} aria-hidden="true" /><span>Roles &amp; access</span>
				</a>
			{/if}
			{#if president}
				<a
					class="side-item"
					href="/app/audit"
					aria-current={path.startsWith('/app/audit') ? 'page' : undefined}
				>
					<FileText size={18} strokeWidth={1.5} aria-hidden="true" /><span>Audit log</span>
				</a>
			{/if}
		</nav>
		<div class="side-footer"><span class="version">v2.0</span></div>
	</aside>

	<div class="main">
		<header class="topbar">
			<span class="breadcrumb">{pageTitle}</span>
			<Popover.Root>
				<Popover.Trigger class="bell" aria-label="Notifications">
					<Bell size={19} strokeWidth={1.5} aria-hidden="true" />
				</Popover.Trigger>
				<Popover.Portal>
					<Popover.Content class="popover notifications" sideOffset={10} align="end">
						<p class="pop-title">Notifications</p>
						<div class="pop-divider"></div>
						<div class="pop-empty">
							<RootImage pose="notifications" class="pop-root" sizes="150px" />
							<p class="empty-title">No notifications yet</p>
							<p class="empty-lead">Updates about your money show up here.</p>
						</div>
					</Popover.Content>
				</Popover.Portal>
			</Popover.Root>
			<DropdownMenu.Root>
				<DropdownMenu.Trigger class="avatar" aria-label="Account">
					{@render avatar()}
				</DropdownMenu.Trigger>
				<DropdownMenu.Portal>
					<DropdownMenu.Content class="popover account" sideOffset={10} align="end">
						<div class="identity">
							<span class="identity-avatar" aria-hidden="true">
								{#if person?.hasPhoto}<img src="/api/profile/photo" alt="" />{:else}<UserRound
										size={20}
										strokeWidth={1.6}
									/>{/if}
							</span>
							<span class="identity-text">
								{#if person?.name}<span class="identity-name">{person.name}</span>
								{:else if summary}<span class="identity-name">{summary.tenantName}</span>{/if}
								{#if uid}<span class="identity-uid">{uid}</span>{/if}
							</span>
						</div>
						<div class="pop-divider"></div>
						<div class="menu-group">
							<DropdownMenu.Item class="menu-row" onSelect={switchWorkspace}>
								<ArrowLeftRight size={16} strokeWidth={1.8} aria-hidden="true" />
								<span class="menu-label">Switch workspace</span>
							</DropdownMenu.Item>
							<DropdownMenu.CheckboxItem
								class="menu-row"
								checked={shell.hideAmounts}
								onCheckedChange={(value) => shell.setHideAmounts(value)}
								closeOnSelect={false}
							>
								{#snippet children({ checked })}
									<EyeOff size={16} strokeWidth={1.8} aria-hidden="true" />
									<span class="menu-label">Hide amounts</span>
									<span class="toggle" class:on={checked} aria-hidden="true"
										><span class="knob"></span></span
									>
								{/snippet}
							</DropdownMenu.CheckboxItem>
						</div>
						<div class="pop-divider"></div>
						<div class="appearance">
							<span class="appearance-label" id="appearance-label">Appearance</span>
							<DropdownMenu.RadioGroup
								class="segmented"
								value={appearance.theme}
								onValueChange={(value) => appearance.set(value)}
								aria-labelledby="appearance-label"
							>
								{#each ['light', 'dark', 'system'] as const as option (option)}
									<DropdownMenu.RadioItem class="segment" value={option} closeOnSelect={false}>
										{THEME_LABELS[option]}
									</DropdownMenu.RadioItem>
								{/each}
							</DropdownMenu.RadioGroup>
						</div>
						<div class="pop-divider"></div>
						<div class="menu-group">
							<DropdownMenu.Item class="menu-row" disabled={!shell.online} onSelect={signOut}>
								<LogOut size={16} strokeWidth={1.8} aria-hidden="true" />
								<span class="menu-label">Sign out</span>
							</DropdownMenu.Item>
						</div>
					</DropdownMenu.Content>
				</DropdownMenu.Portal>
			</DropdownMenu.Root>
		</header>

		{#if !pushed && !tabMore}
			<header class="appbar">
				<button
					type="button"
					class="switcher pill"
					onclick={switchWorkspace}
					aria-label={summary ? `${summary.tenantName}: switch workspace` : 'Switch workspace'}
				>
					{@render brandTile()}
					{@render workspaceLabel()}
					<ChevronsUpDown size={14} strokeWidth={1.6} aria-hidden="true" />
				</button>
				<div class="appbar-actions">
					<a class="bell" href="/app/notifications" aria-label="Notifications">
						<Bell size={19} strokeWidth={1.5} aria-hidden="true" />
					</a>
					<a class="avatar" href="/app/more" aria-label="Account">{@render avatar()}</a>
				</div>
			</header>
		{/if}

		<main class="content" id="main">
			{#if updated.current}
				<div class="banner update" role="status">
					<RotateCw size={20} strokeWidth={2} aria-hidden="true" />
					<span class="banner-copy"
						><span class="wide">A new version of Elivate Wallet is ready</span><span class="narrow"
							>A new version is ready</span
						></span
					>
					<button type="button" class="reload" onclick={reloadForUpdate}>Reload</button>
				</div>
			{/if}

			{#if shell.state.kind === 'offline' && shell.state.summary}
				<div class="banner offline" role="status">
					<WifiOff size={18} strokeWidth={2} aria-hidden="true" />
					<span class="banner-text">
						<span class="banner-title"
							>{shell.state.savedAt
								? staleLabel(shell.state.savedAt, true)
								: 'You’re offline'}</span
						>
						<span class="banner-sub">Actions are unavailable until you reconnect.</span>
					</span>
					<button type="button" class="retry-link" onclick={() => shell.load()}>Retry</button>
				</div>
			{/if}

			{#if needsData && shell.state.kind === 'error'}
				<RootHero
					pose="load-error"
					title="We couldn’t load your workspace"
					lead="Something went wrong on our side."
				/>
				<div class="hero-actions">
					<button type="button" class="primary" onclick={() => shell.load()}>Try again</button>
					{#if shell.state.reference}
						<p class="reference">
							<span>Reference</span><span class="ref-code">{shell.state.reference}</span>
						</p>
					{/if}
				</div>
			{:else if needsData && shell.state.kind === 'offline' && !shell.state.summary}
				<RootHero
					pose="offline-empty"
					title="You’re offline"
					lead="Wallet data needs a connection the first time."
				/>
				<div class="hero-actions">
					<button type="button" class="primary" onclick={() => shell.load()}>Try again</button>
				</div>
			{:else}
				{@render children()}
			{/if}
		</main>

		{#if !pushed}
			<nav class="tabbar" aria-label="Main">
				<a class="tab" href="/app" aria-current={path === '/app' ? 'page' : undefined}>
					<House size={20} strokeWidth={path === '/app' ? 2 : 1.8} aria-hidden="true" /><span
						>Home</span
					>
				</a>
				<a class="tab" href="/app/more" aria-current={tabMore ? 'page' : undefined}>
					<Ellipsis size={20} strokeWidth={1.8} aria-hidden="true" /><span>More</span>
				</a>
			</nav>
		{/if}
	</div>
</div>

<InstallHint />

<style>
	.shell {
		--shell-line: #1f2324;
		--shell-sidebar: #0d0f10;
		--shell-field: #141718;
		--shell-edge: #2a2f31;
		--shell-strong: #d5dadb;
		--shell-faint: #7d8588;
		--shell-active: #1f2324;
		--shell-coral-tint: #3a251f;

		display: flex;
		min-height: 100dvh;
		background: var(--color-canvas);
	}

	:global([data-theme='light']) .shell {
		--shell-line: var(--color-border);
		--shell-sidebar: var(--color-surface);
		--shell-field: var(--color-raised);
		--shell-edge: var(--color-border);
		--shell-strong: var(--color-text);
		--shell-faint: var(--color-muted);
		--shell-active: var(--color-raised);
		--shell-coral-tint: var(--color-accent-subtle);
	}

	@media (prefers-color-scheme: light) {
		:global([data-theme='system']) .shell {
			--shell-line: var(--color-border);
			--shell-sidebar: var(--color-surface);
			--shell-field: var(--color-raised);
			--shell-edge: var(--color-border);
			--shell-strong: var(--color-text);
			--shell-faint: var(--color-muted);
			--shell-active: var(--color-raised);
			--shell-coral-tint: var(--color-accent-subtle);
		}
	}

	/* ── Sidebar (desktop) ─────────────────────────────────────────── */

	.sidebar,
	.topbar {
		display: none;
	}

	.switcher-block {
		display: flex;
		padding: 12px 12px 10px;
		border-bottom: 1px solid var(--shell-line);
	}

	.switcher {
		display: flex;
		align-items: center;
		flex: 1;
		gap: 10px;
		min-width: 0;
		height: 52px;
		padding: 0 8px 0 7px;
		border: 1px solid var(--shell-edge);
		border-radius: 14px;
		background: var(--color-surface);
		box-shadow: #ffffff0a 0px 1px 0px inset;
		color: var(--color-text);
		text-align: left;
		cursor: pointer;
	}

	.brand-tile {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 38px;
		height: 38px;
		border: 1px solid #ff7f4f33;
		border-radius: 10px;
		background: #2a1e1a;
	}

	.brand-tile img {
		width: 20px;
		height: 20px;
	}

	.ws-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		align-items: flex-start;
		gap: 3px;
		min-width: 0;
		overflow: clip;
	}

	.ws-name {
		max-width: 100%;
		overflow: hidden;
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.ws-chip {
		padding: 1px 7px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--shell-strong);
		font-size: 11px;
		font-weight: var(--font-weight-medium);
		line-height: 15px;
	}

	.chev-circle {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 28px;
		height: 28px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--shell-strong);
	}

	.side-nav {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		padding: 14px 12px;
	}

	.side-item {
		display: flex;
		align-items: center;
		gap: 12px;
		height: 38px;
		padding: 0 12px;
		border-radius: 9px;
		color: var(--shell-strong);
		font-size: var(--text-14);
		line-height: 18px;
		text-decoration: none;
	}

	.side-item :global(svg) {
		color: var(--color-muted);
	}

	.side-item[aria-current='page'] {
		background: var(--shell-active);
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.side-item[aria-current='page'] :global(svg) {
		color: var(--color-accent);
	}

	.side-footer {
		display: flex;
		align-items: center;
		justify-content: flex-end;
		gap: 8px;
		padding: 14px 16px;
		border-top: 1px solid var(--shell-line);
	}

	.version {
		color: var(--shell-faint);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	/* ── Top bar (desktop) / app bar (mobile) ──────────────────────── */

	.main {
		display: flex;
		flex: 1;
		flex-direction: column;
		min-width: 0;
	}

	.breadcrumb {
		flex: 1;
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: 18px;
	}

	:global(.bell),
	:global(.avatar) {
		position: relative;
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		border: 0;
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--shell-strong);
		cursor: pointer;
	}

	:global(.bell) {
		width: var(--hit-min);
		height: var(--hit-min);
	}

	:global(.avatar) {
		width: 36px;
		height: 36px;
		background: var(--shell-edge);
		color: var(--color-text);
	}

	.appbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: calc(4px + env(safe-area-inset-top)) 20px 12px;
	}

	.switcher.pill {
		flex: 0 1 auto;
		height: 48px;
		padding: 0 12px 0 5px;
		border-radius: var(--radius-pill);
	}

	.switcher.pill .brand-tile {
		border-radius: var(--radius-pill);
	}

	.switcher.pill .brand-tile img {
		width: 18px;
		height: 18px;
	}

	.switcher.pill .ws-text {
		gap: 2px;
	}

	.switcher.pill .ws-chip {
		padding: 0 6px;
		font-size: 10px;
		line-height: 14px;
	}

	.switcher.pill > :global(svg) {
		flex-shrink: 0;
		color: var(--shell-strong);
	}

	.appbar-actions {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	/* ── Content ───────────────────────────────────────────────────── */

	.content {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 24px;
		width: 100%;
		padding: 8px 20px calc(128px + env(safe-area-inset-bottom));
	}

	.pushed .content {
		padding: 0;
	}

	.banner {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 14px 16px;
		border-radius: var(--radius-16);
	}

	.banner.update {
		border: 1px solid #ff7f4f40;
		background: var(--shell-coral-tint);
	}

	.banner.update > :global(svg) {
		flex-shrink: 0;
		width: 18px;
		height: 18px;
		color: #ff9a6e;
	}

	.banner-copy {
		flex: 1;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.banner-copy .wide {
		display: none;
	}

	.reload {
		flex-shrink: 0;
		min-height: 32px;
		padding: 0 14px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--color-accent);
		color: var(--button-primary-ink);
		font-size: 13px;
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-16);
		cursor: pointer;
	}

	.banner.offline {
		align-items: flex-start;
		border: 1px solid color-mix(in oklab, var(--color-info) 20%, transparent);
		background: color-mix(in oklab, var(--color-info) 14%, var(--color-canvas));
	}

	.banner.offline > :global(svg) {
		flex-shrink: 0;
		color: var(--color-info);
	}

	.banner-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 3px;
	}

	.banner-title {
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.banner-sub {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: 17px;
	}

	.retry-link {
		min-height: 24px;
		padding: 0;
		border: 0;
		background: transparent;
		color: var(--color-info);
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-16);
		cursor: pointer;
	}

	.hero-actions {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.primary {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 52px;
		padding: 0 26px;
		border: 0;
		border-radius: var(--radius-pill);
		background-image: linear-gradient(
			in oklab 135deg,
			oklab(78.7% 0.097 0.085) 0%,
			oklab(73.5% 0.128 0.109) 55%,
			oklab(68.6% 0.137 0.113) 100%
		);
		box-shadow:
			#ffffff59 0px 1px 0px inset,
			#ff7f4f99 0px 10px 28px -10px;
		color: var(--button-primary-ink);
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
		cursor: pointer;
	}

	.reference {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		min-height: var(--hit-min);
		color: var(--color-muted);
		font-size: 13px;
		line-height: var(--leading-16);
	}

	.ref-code {
		color: var(--shell-strong);
		font-family: var(--font-mono);
		letter-spacing: var(--tracking-label);
	}

	/* ── Floating tab bar (mobile) ─────────────────────────────────── */

	.tabbar {
		position: fixed;
		left: 16px;
		right: 16px;
		bottom: calc(24px + env(safe-area-inset-bottom));
		z-index: 3;
		display: flex;
		align-items: center;
		justify-content: space-around;
		height: 68px;
		padding: 0 10px;
		border: 1px solid #ffffff1f;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--shell-active) 85%, transparent);
		box-shadow:
			#ffffff0f 0px 1px 0px inset,
			#000000b3 0px 18px 40px -12px;
		backdrop-filter: blur(20px);
	}

	:global([data-theme='light']) .tabbar {
		border-color: var(--color-border);
		box-shadow: #2126281f 0px 18px 40px -12px;
	}

	.tab {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		gap: 3px;
		width: 76px;
		height: 52px;
		border-radius: var(--radius-pill);
		color: var(--color-muted);
		font-size: 11px;
		line-height: 14px;
		text-decoration: none;
	}

	.tab[aria-current='page'] {
		background: var(--shell-coral-tint);
		color: var(--color-accent);
		font-weight: var(--font-weight-semibold);
	}

	/* ── Popovers (account menu, notifications) ────────────────────── */

	:global(.popover) {
		z-index: 10;
		display: flex;
		flex-direction: column;
		overflow: clip;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-16);
		background: var(--color-surface);
		box-shadow: #00000080 0px 24px 48px -16px;
		color: var(--color-text);
	}

	:global(.popover.account) {
		width: 300px;
	}

	:global(.popover.notifications) {
		width: 380px;
	}

	:global(.pop-divider) {
		height: 1px;
		background: #ffffff0f;
	}

	:global([data-theme='light'] .pop-divider) {
		background: var(--color-border);
	}

	:global(.pop-title) {
		padding: 16px 16px 12px 20px;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-20);
	}

	:global(.pop-empty) {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 6px;
		padding: 20px 24px 28px;
		text-align: center;
	}

	:global(.pop-root) {
		width: 150px;
		height: 200px;
	}

	:global(.empty-title) {
		padding-top: 8px;
		font-size: 17px;
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-24);
	}

	:global(.empty-lead) {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	:global(.identity) {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 16px;
	}

	:global(.identity-avatar) {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 40px;
		height: 40px;
		border-radius: var(--radius-pill);
		background: #3a251f;
		color: #ff9c77;
		overflow: hidden;
	}

	:global(.identity-text) {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	:global(.identity-name) {
		overflow: hidden;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-20);
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	:global(.identity-uid) {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		letter-spacing: var(--tracking-label);
		line-height: var(--leading-16);
	}

	:global(.menu-group) {
		display: flex;
		flex-direction: column;
		gap: 2px;
		padding: 8px;
	}

	:global(.menu-row) {
		display: flex;
		align-items: center;
		gap: 12px;
		height: 40px;
		padding: 0 10px;
		border-radius: var(--radius-8);
		font-size: var(--text-14);
		line-height: var(--leading-20);
		cursor: pointer;
		outline: none;
	}

	:global(.menu-row[data-highlighted]) {
		background: var(--color-raised);
	}

	:global(.menu-row[data-disabled]) {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	:global(.menu-label) {
		flex: 1;
	}

	:global(.toggle) {
		display: flex;
		align-items: center;
		width: 36px;
		height: 20px;
		padding: 2px;
		border-radius: var(--radius-pill);
		background: var(--color-border);
	}

	:global(.toggle .knob) {
		width: 16px;
		height: 16px;
		border-radius: var(--radius-pill);
		background: var(--color-muted);
	}

	:global(.toggle.on) {
		justify-content: flex-end;
		background: var(--color-accent);
	}

	:global(.toggle.on .knob) {
		background: var(--button-primary-ink);
	}

	:global(.appearance) {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 12px 16px;
	}

	:global(.appearance-label) {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	:global(.segmented) {
		display: flex;
		padding: 3px;
		border: 1px solid var(--color-border);
		border-radius: 10px;
		background: #141718;
	}

	:global([data-theme='light'] .segmented) {
		background: var(--color-raised);
	}

	:global(.segment) {
		display: flex;
		align-items: center;
		justify-content: center;
		flex: 1;
		height: 30px;
		border-radius: var(--radius-8);
		color: var(--color-muted);
		font-size: 13px;
		line-height: var(--leading-16);
		cursor: pointer;
		outline: none;
	}

	:global(.segment[data-highlighted]) {
		color: var(--color-text);
	}

	:global(.segment[data-state='checked']) {
		background: #2c3133;
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	:global([data-theme='light'] .segment[data-state='checked']) {
		background: var(--color-surface);
	}

	@media (prefers-color-scheme: light) {
		:global([data-theme='system'] .segmented) {
			background: var(--color-raised);
		}

		:global([data-theme='system'] .segment[data-state='checked']) {
			background: var(--color-surface);
		}

		:global([data-theme='system'] .pop-divider) {
			background: var(--color-border);
		}
	}

	/* ── Desktop ───────────────────────────────────────────────────── */

	@media (min-width: 1024px) {
		.sidebar {
			position: sticky;
			top: 0;
			display: flex;
			flex-direction: column;
			flex-shrink: 0;
			width: 260px;
			height: 100dvh;
			border-right: 1px solid var(--shell-line);
			background: var(--shell-sidebar);
		}

		.topbar {
			display: flex;
			align-items: center;
			gap: 8px;
			flex-shrink: 0;
			height: 64px;
			padding: 0 28px 0 40px;
			border-bottom: 1px solid var(--shell-line);
		}

		.topbar :global(.bell) {
			width: 40px;
			height: 40px;
		}

		.appbar,
		.tabbar {
			display: none;
		}

		.content {
			padding: 32px 40px 40px;
		}

		.pushed .content {
			padding: 32px 40px 40px;
		}

		.banner.update {
			gap: 14px;
			padding: 14px 16px 14px 20px;
		}

		.banner.update > :global(svg) {
			width: 20px;
			height: 20px;
		}

		.banner-copy {
			font-size: 15px;
			line-height: var(--leading-20);
		}

		.banner-copy .wide {
			display: inline;
		}

		.banner-copy .narrow {
			display: none;
		}

		.reload {
			min-height: 36px;
			padding: 0 16px;
			font-size: var(--text-14);
			line-height: var(--leading-20);
		}

		.hero-actions {
			flex-direction: row;
			align-items: center;
			gap: 12px;
		}

		.primary {
			height: 48px;
		}

		.reference {
			height: 48px;
			padding: 0 8px;
		}
	}

	:global(.identity-avatar img) {
		width: 100%;
		height: 100%;
		border-radius: inherit;
		object-fit: cover;
	}
</style>
