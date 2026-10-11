<!--
	Signed-in shell, Paper "App — Screens v3" H01–H09: desktop sidebar + top bar,
	mobile app bar + floating bottom nav, account menu (desktop) / More tab
	(mobile), notifications, offline and update banners, load-error and
	offline-empty Root heroes, iOS install hint. Only routes that exist are
	linked; nothing here shows or invents balances (W-00, decision 36a).
	Blueprint 17: the network's team theme (data-team-theme on <html>) and tile,
	⌘K quick search (K01/K02), Support and Branding & settings entries, and the
	PL06 paused view on write pages of a paused network.
	Blueprint 25 (Paper "Navigation v5" NV01–NV03): a sectioned sidebar, the
	floating pill tab bar with a tab set per role (#lib/nav.ts), and a mobile
	app bar with the network's tile.
-->
<script lang="ts">
	import { onMount, setContext, untrack } from 'svelte';
	import { goto, onNavigate, preloadCode } from '$app/navigation';
	import { navigating, page, updated } from '$app/state';
	import { DropdownMenu, Popover } from 'bits-ui';
	import Activity from '@lucide/svelte/icons/activity';
	import ArrowLeftRight from '@lucide/svelte/icons/arrow-left-right';
	import Repeat from '@lucide/svelte/icons/repeat';
	import Undo2 from '@lucide/svelte/icons/undo-2';
	import Bell from '@lucide/svelte/icons/bell';
	import Building from '@lucide/svelte/icons/building-2';
	import CreditCard from '@lucide/svelte/icons/credit-card';
	import CirclePause from '@lucide/svelte/icons/circle-pause';
	import FileText from '@lucide/svelte/icons/file-text';
	import FileIcon from '@lucide/svelte/icons/file';
	import ChartColumn from '@lucide/svelte/icons/chart-column';
	import Shield from '@lucide/svelte/icons/shield';
	import Users from '@lucide/svelte/icons/users';
	import ChevronsUpDown from '@lucide/svelte/icons/chevrons-up-down';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import Download from '@lucide/svelte/icons/download';
	import ListChecks from '@lucide/svelte/icons/list-checks';
	import Gavel from '@lucide/svelte/icons/gavel';
	import Upload from '@lucide/svelte/icons/upload';
	import EyeOff from '@lucide/svelte/icons/eye-off';
	import House from '@lucide/svelte/icons/house';
	import LayoutGrid from '@lucide/svelte/icons/layout-grid';
	import Landmark from '@lucide/svelte/icons/landmark';
	import MailPlus from '@lucide/svelte/icons/mail-plus';
	import PieChart from '@lucide/svelte/icons/chart-pie';
	import LogOut from '@lucide/svelte/icons/log-out';
	import RotateCw from '@lucide/svelte/icons/rotate-cw';
	import UserRound from '@lucide/svelte/icons/user-round';
	import UserCog from '@lucide/svelte/icons/user-cog';
	import WalletIcon from '@lucide/svelte/icons/wallet';
	import WifiOff from '@lucide/svelte/icons/wifi-off';
	import Palette from '@lucide/svelte/icons/palette';
	import Search from '@lucide/svelte/icons/search';
	import CircleHelp from '@lucide/svelte/icons/circle-help';
	import { Appearance, THEME_LABELS } from '#lib/client/appearance.svelte.js';
	import { purgeAllDeviceData, staleLabel } from '#lib/client/device-cache.js';
	import { profilePhotoSrc } from '#lib/client/photo.js';
	import { ownWalletBlocked, type OwnWalletPermission } from '#lib/own-wallet.js';
	import { currentTab, isCurrent, navModel, type NavModel } from '#lib/nav.js';
	import NavIcon from '#lib/ui/app/NavIcon.svelte';
	import { Shell } from '#lib/client/shell.svelte.js';
	import { pinLock } from '#lib/client/pin-lock.svelte.js';
	import PinUnlock from '#lib/ui/app/PinUnlock.svelte';
	import { Bell as BellState } from '#lib/client/bell.svelte.js';
	import NotificationList from '#lib/ui/app/NotificationList.svelte';
	import { ROLE_LABELS } from '#lib/labels.js';
	import InstallHint from '#lib/ui/app/InstallHint.svelte';
	import NoAccess from '#lib/ui/app/NoAccess.svelte';
	import PausedView from '#lib/ui/app/PausedView.svelte';
	import QuickSearch from '#lib/ui/app/QuickSearch.svelte';
	import { isSearchShortcut, type SearchPage } from '#lib/client/search.js';
	import { pausedWriteRoute } from '#lib/paused.js';
	import { OPERATION_NAMES, pausedCopy, stoppedHere } from '#lib/operations.js';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';
	import PageFrame from '#lib/ui/app/PageFrame.svelte';
	import { warmRoutes } from '#lib/client/warm-routes.js';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();

	// Slice 28: decided before any page mounts, so a stale session never shows a saved copy.
	pinLock.prime();
	const shell = new Shell();
	const appearance = new Appearance();
	/** Blueprint 13: the bell follows the selected workspace. */
	const bell = new BellState(
		() => (shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null),
		// Blueprint 23: the lists the bell loads are kept for this person and workspace.
		() => shell.scope
	);
	setContext('shell', shell);
	setContext('bell', bell);
	let bellOpen = $state(false);
	const bellLabel = $derived(
		bell.unread > 0 ? `Notifications, ${bell.unread} unread` : 'Notifications'
	);
	// Poll the badge only while the shell is live in a workspace.
	const live = $derived(shell.state.kind === 'ready');
	$effect(() => {
		if (!live) return;
		return bell.start();
	});
	// Opening the bell loads it; one opened before the workspace was known loads once it is.
	const bellWorkspace = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.membershipId : null
	);
	$effect(() => {
		if (bellWorkspace && bellOpen) untrack(() => void bell.load(bell.view));
	});
	setContext('appearance', appearance);

	let signOutForm: HTMLFormElement | undefined = $state();
	setContext('signOut', signOut);

	onMount(() => {
		appearance.start();
		// Slice 28: a PIN owed locks in place; the idle check asks the server.
		const stopLock = pinLock.start(() => void shell.load());
		const stopShell = shell.start();
		return () => {
			stopLock();
			stopShell();
		};
	});

	const summary = $derived(
		shell.state.kind === 'ready' || shell.state.kind === 'offline' ? shell.state.summary : null
	);
	const uid = $derived(shell.state.kind === 'ready' ? shell.state.view.state.uid : null);
	const person = $derived(shell.state.kind === 'ready' ? shell.state.view.profile : null);
	const photoSrc = $derived(profilePhotoSrc(person));
	/** A photo that failed to load falls back to the initials (Blueprint 25). */
	let brokenPhoto = $state<string | null>(null);
	const path = $derived(page.url.pathname);
	/**
	 * Blueprint 23: where the person is going. The tab bar, the sidebar and the
	 * title follow a tap at once (\`navigating.to\`), not only once the page
	 * has loaded.
	 */
	const navPath = $derived(navigating.to?.url.pathname ?? path);
	/**
	 * Blueprint 25: tabs, sidebar sections and Home's kind, derived once from
	 * the capabilities (navigation hints only; the backend authorizes).
	 */
	const nav: NavModel = $derived(
		navModel({
			permissions:
				shell.state.kind === 'ready' ? (shell.state.view.capabilities?.permissions ?? []) : null,
			role: summary?.role ?? null,
			billingOwner:
				shell.state.kind === 'ready' && shell.state.view.capabilities?.billingOwner === true,
			tasks: bell.tasks,
			networkHomeHint: summary?.networkHome
		})
	);
	// Blueprint 25: the bell reads the live tasks on every poll for people who approve.
	$effect(() => {
		bell.watchTasks = nav.approvals.length > 0;
	});
	setContext('nav', () => nav);
	const tabNow = $derived(currentTab(nav.tabs, navPath));
	const initials = $derived(
		(person?.name ?? '')
			.split(/\s+/)
			.filter(Boolean)
			.slice(0, 2)
			.map((word) => word.charAt(0).toUpperCase())
			.join('')
	);
	/** Navigation hint only; every command is still authorized by the backend. */
	const TITLES: Record<string, string> = {
		// Blueprint 10 (Paper S03/S05 breadcrumbs); most specific first.
		'/app/account/devices': 'Profile & security  /  Devices & sessions',
		'/app/account/pin': 'Profile & security  /  Transaction PIN',
		'/app/account/password': 'Profile & security  /  Password',
		'/app/account': 'Profile & security',
		'/app/activity': 'Activity',
		'/app/withdrawals/new': 'Withdrawals  /  New request',
		'/app/withdrawals': 'Withdrawals',
		'/app/queue/returns': 'Withdrawal queue  /  Returned funds',
		'/app/queue': 'Withdrawal queue',
		'/app/convert': 'Record conversion',
		'/app/adjust': 'Members  /  Adjustment',
		'/app/reversals': 'Reversals',
		'/app/transfers': 'Transfers',
		'/app/evidence': 'Evidence review',
		'/app/split/move': 'Pockets & split  /  Move money',
		'/app/team': 'Team overview',
		'/app/wallet': 'My wallet',
		'/app/wallets': 'Member wallets',
		'/app/payout-accounts': 'Payout accounts',
		'/app/statements': 'Statements',
		'/app/reports': 'Reports',
		'/app/income': 'Record income',
		'/app/invitations': 'Invitations',
		'/app/split': 'Pockets & split',
		'/app/reviews': 'NIN reviews',
		'/app/notifications': 'Notifications',
		'/app/more': 'More',
		'/app/offices': 'Offices',
		'/app/members': 'Members',
		'/app/access': 'Roles & access',
		'/app/audit': 'Audit log',
		'/app/billing/payments': 'Billing  /  Payment',
		'/app/billing': 'Billing',
		// Blueprint 17 (Paper F01/F02/E09/V01 breadcrumbs).
		'/app/settings/backups/restore': 'Settings  /  Backup vault  /  Request a restore',
		'/app/settings/backups': 'Settings  /  Backup vault',
		'/app/settings/details': 'Settings  /  Team details',
		'/app/settings': 'Settings  /  Branding',
		'/app/support': 'Support'
	};
	const pageTitle = $derived(
		Object.entries(TITLES).find(([prefix]) => navPath.startsWith(prefix))?.[1] ??
			// Blueprint 17 (Paper X01): an unknown page is "Not found", not Home.
			(page.route.id === '/app/[...missing]'
				? 'Not found'
				: nav.networkHome && summary?.role === 'president_team_member'
					? 'Network overview'
					: 'Home')
	);
	const can = (permission: string) =>
		shell.state.kind === 'ready' &&
		(shell.state.view.capabilities?.permissions ?? []).includes(permission);
	/**
	 * Slice 21: own-money entries follow the own-wallet permissions, which the
	 * President Team never holds (A-03). Before they load (or offline) the
	 * role stands in, so a member's Activity stays reachable offline.
	 */
	const ownMoney = (permission: OwnWalletPermission) =>
		shell.state.kind === 'ready'
			? can(permission)
			: !!summary && summary.role !== 'president_team_member';
	const ownBlocked = $derived(
		ownWalletBlocked(
			path,
			shell.state.kind === 'ready' ? (shell.state.view.capabilities?.permissions ?? []) : null
		)
	);
	/** Org management entries (Blueprint 07); navigation hints only. */
	const president = $derived(summary?.role === 'president_team_member');
	const leads = $derived(president || can('manage_members') || can('view_managed_wallets'));
	/** Slice 28: Offices is for the President Team and World Team only. */
	const runsOffices = $derived(president || summary?.role === 'world_team_member');
	const officesBlocked = $derived(
		!!summary && !runsOffices && (path === '/app/offices' || path.startsWith('/app/offices/'))
	);
	/** Pushed pages (mobile Notifications) have their own nav bar and no tabs. */
	const pushed = $derived(
		path.startsWith('/app/notifications') ||
			path.startsWith('/app/income') ||
			path === '/app/withdrawals/new' ||
			path.startsWith('/app/convert') ||
			path.startsWith('/app/adjust') ||
			path.startsWith('/app/reversals') ||
			path.startsWith('/app/queue/returns') ||
			path.startsWith('/app/account') ||
			path.startsWith('/app/statements') ||
			path.startsWith('/app/reports') ||
			path.startsWith('/app/support') ||
			(path.startsWith('/app/activity') && page.url.searchParams.has('tx'))
	);
	/** Leadership views (W-07); the backend authorizes every read. */
	const leader = $derived(can('view_managed_wallets') || can('view_scoped_financial_reports'));
	/** Blueprint 15: the Reports page (S05/S12); the backend authorizes every read. */
	const reports = $derived(can('view_scoped_financial_reports') || can('export_scoped_reports'));
	const tabMore = $derived(path.startsWith('/app/more'));
	/**
	 * Blueprint 16: Billing for manage_subscription holders and the Billing
	 * Owner (owner decision 2026-10-05); the backend decides every read.
	 */
	const billing = $derived(
		can('manage_subscription') ||
			(shell.state.kind === 'ready' && shell.state.view.capabilities?.billingOwner === true)
	);
	const tenantStatus = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.tenantStatus : null
	);
	// A network still awaiting its first payment only has Billing (PL03/PL11).
	$effect(() => {
		if (tenantStatus === 'pending_payment' && !path.startsWith('/app/billing')) {
			void goto('/app/billing');
		}
	});
	/** Only Home needs workspace data; More and Notifications keep their controls. */
	const needsData = $derived(path === '/app' || path === '/app/wallet');

	async function reloadForUpdate() {
		const registration = await navigator.serviceWorker?.getRegistration();
		registration?.waiting?.postMessage({ type: 'SKIP_WAITING' });
		window.location.reload();
	}

	function signOut() {
		purgeAllDeviceData();
		signOutForm?.requestSubmit();
	}

	/**
	 * Blueprint 23: the picker opens inside the app (its code is preloaded, and
	 * its server load is the one round trip it always needed). Choosing a
	 * workspace still posts the picker's form, which sets the cookies and
	 * reloads /app for the new workspace.
	 */
	const switchWorkspace = () => goto('/workspaces?switch');

	// ── Blueprint 23: instant taps ───────────────────────────────────────
	// Every screen's code, once the shell is ready and the browser is idle.
	$effect(() => {
		if (shell.state.kind === 'ready') untrack(() => void warmRoutes(preloadCode));
	});
	/**
	 * A tap whose page is not ready within a few frames shows a light page
	 * frame (title and placeholders) instead of the old page.
	 */
	let slowNav = $state(false);
	$effect(() => {
		const to = navigating.to?.url.pathname;
		if (!to || to === path || !to.startsWith('/app') || navigating.type === 'form') return;
		const timer = setTimeout(() => (slowNav = true), 80);
		return () => {
			clearTimeout(timer);
			slowNav = false;
		};
	});
	/**
	 * A short page swap (≤ 200 ms) where the browser has view transitions and
	 * motion is welcome. It starts only once the new page is ready (onNavigate
	 * runs right before the swap), so it never delays the navigation.
	 */
	onNavigate((navigation) => {
		if (!document.startViewTransition) return;
		if (navigation.from?.url.pathname === navigation.to?.url.pathname) return;
		if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
		const root = document.documentElement;
		return new Promise<void>((resolve) => {
			root.dataset.pageSwap = '';
			const swap = document.startViewTransition(async () => {
				resolve();
				await navigation.complete.catch(() => undefined);
			});
			void swap.finished.finally(() => delete root.dataset.pageSwap);
		});
	});

	// ── Blueprint 17: brand, team theme, settings, quick search ──────────
	const brand = $derived(shell.state.kind === 'ready' ? (shell.state.view.brand ?? null) : null);
	const teamTheme = $derived(brand?.theme ?? summary?.theme ?? 'ember');
	// On <html> so dialogs (portalled to <body>) follow the theme too.
	$effect(() => {
		const root = document.documentElement;
		if (teamTheme === 'ember') delete root.dataset.teamTheme;
		else root.dataset.teamTheme = teamTheme;
		return () => {
			delete root.dataset.teamTheme;
		};
	});
	/** Revisions count per network: the network keeps cached icons apart (slice 21). */
	const brandTenant = $derived(
		shell.state.kind === 'ready' ? shell.state.view.workspace.tenantId : ''
	);
	const tileInitial = $derived(
		(brand?.name ?? summary?.tenantName ?? '').trim().charAt(0).toUpperCase()
	);
	/** Branding & settings: Presidents edit; World Team only reaches the vault (W-24). */
	const settings = $derived(can('manage_team_settings') || can('request_restore'));
	const settingsHref = $derived(
		can('manage_team_settings') ? '/app/settings' : '/app/settings/backups'
	);

	let searchOpen = $state(false);
	/** Blueprint 25: More opens quick search on phones (the app bar has no search button). */
	setContext('openSearch', () => (searchOpen = true));
	/** Blueprint 25: More shows the same network tile as the bars. */
	setContext('brandTile', () => brandTile);
	function onKeydown(event: KeyboardEvent) {
		if (shell.state.kind !== 'ready' || !isSearchShortcut(event)) return;
		event.preventDefault();
		searchOpen = !searchOpen;
	}
	/** Pages quick search may offer: the same hints as the navigation. */
	const searchPages = $derived.by((): SearchPage[] => {
		const pages: (SearchPage | false)[] = [
			{ label: 'Home', href: '/app', icon: House },
			ownMoney('view_own_financials') && {
				label: 'Activity',
				href: '/app/activity',
				keywords: 'transactions history',
				icon: Activity
			},
			can('initiate_own_withdrawal') && {
				label: 'Withdrawals',
				href: '/app/withdrawals',
				keywords: 'withdraw cash out',
				icon: Upload
			},
			can('approve_withdrawal') && {
				label: 'Withdrawal queue',
				href: '/app/queue',
				keywords: 'approve payouts',
				icon: ListChecks
			},
			can('approve_pocket_transfer') && {
				label: 'Transfers',
				href: '/app/transfers',
				keywords: 'pocket moves',
				icon: ArrowLeftRight
			},
			can('reverse_transaction') && { label: 'Reversals', href: '/app/reversals', icon: Undo2 },
			can('review_financial_evidence') && {
				label: 'Evidence review',
				href: '/app/evidence',
				keywords: 'evidence receipts',
				icon: Gavel
			},
			leader && { label: 'Team overview', href: '/app', keywords: 'home', icon: LayoutGrid },
			leader &&
				ownMoney('view_own_wallet') && {
					label: 'My wallet',
					href: '/app/wallet',
					keywords: 'balance pockets',
					icon: WalletIcon
				},
			leader && { label: 'Member wallets', href: '/app/wallets', icon: WalletIcon },
			reports && {
				label: 'Reports & exports',
				href: '/app/reports',
				keywords: 'csv pdf',
				icon: ChartColumn
			},
			ownMoney('manage_own_payout_accounts') && {
				label: 'Payout accounts',
				href: '/app/payout-accounts',
				keywords: 'bank',
				icon: Landmark
			},
			ownMoney('export_own_statement') && {
				label: 'Statements',
				href: '/app/statements',
				icon: FileIcon
			},
			can('record_income') && { label: 'Record income', href: '/app/income', icon: Download },
			can('perform_currency_conversion') && {
				label: 'Record conversion',
				href: '/app/convert',
				keywords: 'convert',
				icon: Repeat
			},
			can('invite_members') && {
				label: 'Invitations',
				href: '/app/invitations',
				keywords: 'invite',
				icon: MailPlus
			},
			{ label: 'Pockets & split', href: '/app/split', icon: PieChart },
			runsOffices && { label: 'Offices', href: '/app/offices', icon: Building },
			leads && { label: 'Members', href: '/app/members', keywords: 'people', icon: Users },
			(president || can('manage_access_rules')) && {
				label: 'Roles & access',
				href: '/app/access',
				keywords: 'permissions access',
				icon: Shield
			},
			settings && {
				label: 'Branding & settings',
				href: settingsHref,
				keywords: 'settings theme logo backup restore team details',
				icon: Palette
			},
			billing && {
				label: 'Billing',
				href: '/app/billing',
				keywords: 'plan payment',
				icon: CreditCard
			},
			president && {
				label: 'Audit log',
				href: '/app/audit',
				keywords: 'activity',
				icon: FileText
			},
			{
				label: 'Profile & security',
				href: '/app/account',
				keywords: 'pin password',
				icon: UserCog
			},
			{ label: 'Support', href: '/app/support', keywords: 'help chat contact', icon: CircleHelp },
			{ label: 'Notifications', href: '/app/notifications', icon: Bell }
		];
		return pages.filter((p): p is SearchPage => !!p);
	});
	/** PL06: a write page on a paused network shows the paused view instead. */
	const pausedHere = $derived(tenantStatus === 'suspended' && pausedWriteRoute(path));

	// Blueprint 18: a write page whose operation Elivate has stopped (kill
	// switch) shows a paused banner above the page, which stays usable so an
	// attempt with an unknown outcome can still be checked or cancelled. Read
	// fresh on each write page; the database refuses the operation either way.
	// Blueprint 23: read at most once a minute, not on every tap between write
	// pages (the database still refuses a stopped operation at once).
	const onWritePage = $derived(stoppedHere(path, Object.keys(OPERATION_NAMES)) !== null);
	const STOPPED_FRESH_MS = 60_000;
	let stoppedAt = 0;
	$effect(() => {
		// Track the path itself: moving between write pages may fetch again.
		void path;
		if (!onWritePage || !summary || Date.now() - stoppedAt < STOPPED_FRESH_MS) return;
		const controller = new AbortController();
		fetch('/api/operations', { signal: controller.signal })
			.then((r) => (r.ok ? r.json() : null))
			.then((body: { data?: { stopped?: unknown } } | null) => {
				if (!body) return;
				const list = body.data?.stopped;
				shell.stopped = Array.isArray(list) ? list.filter((x) => typeof x === 'string') : [];
				stoppedAt = Date.now();
			})
			.catch(() => undefined);
		return () => controller.abort();
	});
	const operationHere = $derived(onWritePage ? stoppedHere(path, shell.stopped) : null);
</script>

<svelte:window onkeydown={onKeydown} />

<svelte:head><title>Elivate Wallet</title></svelte:head>

<form method="POST" action="/sign-out" bind:this={signOutForm} hidden></form>

{#snippet workspaceLabel()}
	<!-- Slice 30 (owner 2026-10-11): the network's name only; role and office are on Profile. -->
	<span class="ws-text">
		<span class="ws-name">{brand?.name ?? summary?.tenantName ?? ''}</span>
	</span>
{/snippet}

{#snippet brandTile()}
	<!-- Blueprint 17: the network's square icon, else its initial on the theme colour. -->
	{#if brand?.hasIcon}
		<span class="brand-tile icon" aria-hidden="true"
			><img src="/api/brand/icon?t={brandTenant}&v={brand.revision}" alt="" /></span
		>
	{:else if tileInitial}
		<span class="brand-tile initial" aria-hidden="true">{tileInitial}</span>
	{:else}
		<span class="brand-tile" aria-hidden="true"
			><img src="/icons/mark.svg" alt="" width="20" height="20" /></span
		>
	{/if}
{/snippet}

{#snippet avatar()}
	{#if photoSrc && photoSrc !== brokenPhoto}<img
			class="avatar-photo"
			src={photoSrc}
			alt=""
			onerror={() => (brokenPhoto = photoSrc)}
		/>
	{:else if initials}<span class="avatar-initials" aria-hidden="true">{initials}</span>
	{:else}<UserRound size={18} strokeWidth={1.6} aria-hidden="true" />{/if}
{/snippet}

{#if pinLock.locked}
	<!-- Slice 28: the page and its data are unmounted while the PIN is owed. -->
	<PinUnlock
		firstName={person?.name?.split(' ')[0] ?? null}
		onUnlocked={() => {
			pinLock.unlocked();
			void shell.load();
		}}
		onSignOut={signOut}
	/>
{:else}
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
					<ChevronsUpDown size={16} strokeWidth={2} aria-hidden="true" />
				</button>
			</div>
			<div class="side-search-wrap">
				<button
					type="button"
					class="side-search"
					onclick={() => (searchOpen = true)}
					aria-haspopup="dialog"
					aria-keyshortcuts="Meta+K Control+K"
				>
					<Search size={15} strokeWidth={2} aria-hidden="true" />
					<span class="side-search-label">Quick search…</span>
					<kbd class="side-kbd" aria-hidden="true">⌘K</kbd>
				</button>
			</div>
			<nav class="side-nav">
				{#each nav.sections as section (section.id)}
					<div
						class="side-section"
						role="group"
						aria-labelledby={section.label ? `nav-${section.id}` : undefined}
						aria-label={section.label ? undefined : 'Start'}
					>
						{#if section.label}<span class="side-label" id="nav-{section.id}">{section.label}</span
							>{/if}
						{#each section.items as item (item.id)}
							<a
								class="side-item"
								class:top={section.id === 'top'}
								href={item.href}
								aria-current={isCurrent(item, navPath) ? 'page' : undefined}
							>
								<span class="side-icon"><NavIcon name={item.icon} /></span>
								<span class="side-text">{item.label}</span>
								{#if item.count}<span class="side-count" class:accent={item.accent}
										><span aria-hidden="true">{item.count}</span><span class="visually-hidden"
											>, {item.count} waiting</span
										></span
									>{/if}
							</a>
						{/each}
					</div>
				{/each}
			</nav>
		</aside>

		<div class="main">
			<header class="topbar">
				<span class="breadcrumb">{pageTitle}</span>
				<a
					class="support-link"
					href="/app/support"
					aria-current={path.startsWith('/app/support') ? 'page' : undefined}
				>
					<CircleHelp size={18} strokeWidth={1.6} aria-hidden="true" /><span>Support</span>
				</a>
				<Popover.Root bind:open={bellOpen}>
					<Popover.Trigger class="bell" aria-label={bellLabel} type="button">
						<Bell size={19} strokeWidth={1.5} aria-hidden="true" />
						{#if bell.unread > 0}<span class="bell-dot" aria-hidden="true"></span>{/if}
					</Popover.Trigger>
					<Popover.Portal>
						<Popover.Content class="popover notifications" sideOffset={10} align="end">
							<div class="pop-head">
								<p class="pop-title">Notifications</p>
								{#if bell.unread > 0}
									<button type="button" class="pop-link" onclick={() => bell.markAll()}
										>Mark all as read</button
									>
								{/if}
							</div>
							<div class="pop-tabs" role="group" aria-label="Show">
								<button
									type="button"
									class="pop-tab"
									aria-pressed={bell.view === 'unread'}
									onclick={() => bell.load('unread')}
									>Unread{bell.unread > 0 ? ` · ${bell.unread}` : ''}</button
								>
								<button
									type="button"
									class="pop-tab"
									aria-pressed={bell.view === 'all'}
									onclick={() => bell.load('all')}>All</button
								>
							</div>
							<div class="pop-scroll" tabindex="-1">
								{#if bell.list.kind === 'ready' && (bell.list.actions.length > 0 || bell.list.items.length > 0)}
									<NotificationList
										{bell}
										variant="popover"
										hide={shell.hideAmounts}
										onfollow={() => (bellOpen = false)}
									/>
								{:else if bell.list.kind === 'error'}
									<p class="pop-note" role="alert">Couldn’t load notifications. Try again.</p>
								{:else if bell.list.kind === 'ready'}
									<div class="pop-empty">
										<RootImage pose="notifications" class="pop-root" sizes="150px" />
										{#if bell.view === 'unread'}
											<p class="empty-title">You’re all caught up.</p>
										{:else}
											<p class="empty-title">No notifications yet</p>
											<p class="empty-lead">Updates about your money show up here.</p>
										{/if}
									</div>
								{:else}
									<p class="pop-note">Loading…</p>
								{/if}
							</div>
							<a class="pop-all" href="/app/notifications" onclick={() => (bellOpen = false)}
								>See all notifications</a
							>
						</Popover.Content>
					</Popover.Portal>
				</Popover.Root>
				<DropdownMenu.Root>
					<DropdownMenu.Trigger class="avatar" aria-label="Account" type="button">
						{@render avatar()}
					</DropdownMenu.Trigger>
					<DropdownMenu.Portal>
						<DropdownMenu.Content class="popover account" sideOffset={10} align="end">
							<div class="identity">
								<span class="identity-avatar" aria-hidden="true">
									{#if photoSrc}<img src={photoSrc} alt="" />{:else}<UserRound
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
								<!-- Paper "App — Screens v3" account menu: Profile & security (Blueprint 10). -->
								<DropdownMenu.Item class="menu-row" onSelect={() => goto('/app/account')}>
									<UserCog size={16} strokeWidth={1.8} aria-hidden="true" />
									<span class="menu-label">Profile & security</span>
								</DropdownMenu.Item>
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
						class="ws-button"
						onclick={switchWorkspace}
						aria-label={summary ? `${summary.tenantName}: switch workspace` : 'Switch workspace'}
					>
						{@render brandTile()}
						{@render workspaceLabel()}
						<ChevronDown class="ws-chevron" size={16} strokeWidth={2} aria-hidden="true" />
					</button>
					<div class="appbar-actions">
						<a class="bell" href="/app/notifications" aria-label={bellLabel}>
							<Bell size={19} strokeWidth={1.5} aria-hidden="true" />
							{#if bell.unread > 0}<span class="bell-dot" aria-hidden="true"></span>{/if}
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
							><span class="wide">A new version of Elivate Wallet is ready</span><span
								class="narrow">A new version is ready</span
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

				{#if tenantStatus === 'suspended' && summary}
					<!-- Paper PL06: the network is paused (Blueprint 16); money stays readable. -->
					<div class="banner paused" role="status">
						<CirclePause size={18} strokeWidth={2} aria-hidden="true" />
						<span class="banner-text">
							<span class="banner-title">{summary.tenantName} is paused</span>
							<span class="banner-sub"
								>Your money is safe to view. Withdrawals and moves are off until it’s renewed.</span
							>
						</span>
						{#if billing && !path.startsWith('/app/billing')}
							<a class="retry-link" href="/app/billing">Review billing</a>
						{/if}
					</div>
				{/if}

				{#if operationHere}
					<!-- Blueprint 18: Elivate stopped this operation (kill switch). -->
					<div class="banner paused" role="status">
						<CirclePause size={18} strokeWidth={2} aria-hidden="true" />
						<div class="banner-text">
							<h2 class="banner-title">{pausedCopy(operationHere).title}</h2>
							<span class="banner-sub">{pausedCopy(operationHere).lead}</span>
						</div>
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
				{:else if pausedHere && summary}
					<PausedView network={summary.tenantName} canPay={billing} />
				{:else if officesBlocked}
					<!-- Slice 28: offices are run by the President Team and World Team. -->
					<NoAccess
						title="Not available for your role"
						lead="Offices are managed by the President Team and World Team."
					/>
				{:else if ownBlocked}
					<!-- Slice 21: an own-money page in a workspace that holds no wallet. -->
					<NoAccess
						title="Not available for your role"
						lead="This page is for your own wallet. {summary
							? ROLE_LABELS[summary.role]
							: 'This role'} doesn’t hold one in this workspace."
					/>
				{:else if slowNav}
					<PageFrame title={pageTitle} />
				{:else}
					{@render children()}
				{/if}
			</main>

			{#if !pushed}
				<!-- Blueprint 25: the floating pill bar (Roudio "Fresh Direction"): icons only;
			     the current tab grows into a filled pill with its name. -->
				<nav class="tabbar" aria-label="Main" data-tabs={nav.tabs.length}>
					{#each nav.tabs as tab (tab.id)}
						{@const current = tabNow === tab.id}
						<a
							class="tab"
							href={tab.href}
							data-tab={tab.id}
							aria-current={current ? 'page' : undefined}
						>
							<span class="tab-icon">
								<NavIcon name={tab.icon} size={22} strokeWidth={current ? 2 : 1.8} />
								{#if tab.dot && !current}<span class="tab-dot" aria-hidden="true"></span>{/if}
							</span>
							<span class="tab-label">{tab.label}</span>
							{#if tab.dot}<span class="visually-hidden">, something is waiting</span>{/if}
						</a>
					{/each}
				</nav>
			{/if}
		</div>
	</div>
{/if}

<InstallHint />

{#if shell.state.kind === 'ready' && !pinLock.locked}
	<QuickSearch
		bind:open={searchOpen}
		pages={searchPages}
		hideAmounts={shell.hideAmounts}
		permissions={shell.state.view.capabilities?.permissions ?? []}
	/>
{/if}

<style>
	.shell {
		/*
		 * Slice 21: one height for the desktop top bar and the sidebar's workspace
		 * switcher block (both border-box, bottom border included), so their
		 * dividers sit on the same pixel row at every width.
		 */
		--shell-header: 64px;
		/* Blueprint 25 (Paper NV03): the sidebar sits on the canvas; one line colour. */
		--shell-line: var(--color-raised);
		--shell-sidebar: var(--color-canvas);
		--shell-edge: #2a2f31;
		--shell-strong: #d5dadb;
		--shell-faint: #7d8588;
		--shell-active: #1f2324;
		--shell-count: #2c3133;
		--shell-coral-tint: var(--color-accent-subtle);
		/* The floating pill bar (Paper NV01/NV02). */
		--tab-bg: #1f2324e6;
		--tab-edge: #ffffff1f;
		--tab-shadow: #ffffff0f 0px 1px 0px inset, #000000b3 0px 18px 40px -12px;

		display: flex;
		min-height: 100dvh;
		background: var(--color-canvas);
	}

	:global([data-theme='light']) .shell {
		--shell-line: var(--color-border);
		--shell-edge: var(--color-border);
		--shell-strong: var(--color-text);
		--shell-faint: var(--color-muted);
		--shell-active: var(--color-raised);
		--shell-count: var(--color-raised);
		--shell-coral-tint: var(--color-accent-subtle);
		--tab-bg: color-mix(in oklab, var(--color-surface) 92%, transparent);
		--tab-edge: var(--color-border);
		--tab-shadow: #ffffffb3 0px 1px 0px inset, #2126281f 0px 18px 40px -12px;
	}

	@media (prefers-color-scheme: light) {
		:global([data-theme='system']) .shell {
			--shell-line: var(--color-border);
			--shell-edge: var(--color-border);
			--shell-strong: var(--color-text);
			--shell-faint: var(--color-muted);
			--shell-active: var(--color-raised);
			--shell-count: var(--color-raised);
			--shell-coral-tint: var(--color-accent-subtle);
			--tab-bg: color-mix(in oklab, var(--color-surface) 92%, transparent);
			--tab-edge: var(--color-border);
			--tab-shadow: #ffffffb3 0px 1px 0px inset, #2126281f 0px 18px 40px -12px;
		}
	}

	/* ── Sidebar (desktop), Paper NV03 ──────────────────────────────── */

	.sidebar,
	.topbar {
		display: none;
	}

	.switcher-block {
		display: flex;
		flex-shrink: 0;
		/* 7 + 48 + 8 + 1 px border = the header; whole pixels, no centring offsets. */
		height: var(--shell-header);
		padding: 7px 12px 8px;
		border-bottom: 1px solid var(--shell-line);
	}

	.switcher {
		display: flex;
		align-items: center;
		flex: 1;
		gap: 10px;
		min-width: 0;
		height: 48px;
		padding: 0 8px 0 6px;
		border: 1px solid var(--shell-edge);
		border-radius: var(--radius-12);
		background: var(--color-surface);
		color: var(--color-text);
		font: inherit;
		text-align: left;
		cursor: pointer;
	}

	.switcher > :global(svg) {
		flex-shrink: 0;
		color: var(--color-muted);
	}

	.brand-tile {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 34px;
		height: 34px;
		border: 1px solid var(--color-accent-ring);
		border-radius: 9px;
		background: var(--color-accent-subtle);
	}

	.brand-tile img {
		width: 20px;
		height: 20px;
	}

	/* Slice 30: a quiet initial (no solid coral block); the team logo replaces it. */
	.brand-tile.initial {
		border-color: var(--color-border);
		background: var(--color-raised);
		color: var(--color-accent-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
	}

	.brand-tile.icon {
		overflow: hidden;
		border-color: transparent;
	}

	.brand-tile.icon img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.ws-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		align-items: flex-start;
		gap: 1px;
		min-width: 0;
	}

	.ws-name {
		max-width: 100%;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.ws-name {
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
	}

	.side-search-wrap {
		flex-shrink: 0;
		padding: 14px 12px 6px;
	}

	.side-search {
		display: flex;
		align-items: center;
		gap: 8px;
		width: 100%;
		height: 38px;
		padding: 0 10px;
		border: 1px solid var(--shell-edge);
		border-radius: 10px;
		background: transparent;
		color: var(--color-muted);
		font: inherit;
		font-size: 13px;
		line-height: 18px;
		cursor: pointer;
	}

	.side-search-label {
		flex: 1;
		text-align: left;
	}

	.side-kbd {
		padding: 1px 6px;
		border: 1px solid var(--color-border);
		border-radius: 6px;
		color: var(--color-muted);
		font-family: var(--font-sans);
		font-size: 11px;
		line-height: 14px;
	}

	.side-search:focus-visible,
	.support-link:focus-visible,
	.switcher:focus-visible,
	.ws-button:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 2px;
	}

	.side-nav {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 14px;
		min-height: 0;
		padding: 8px 12px 16px;
		overflow-y: auto;
		scrollbar-width: thin;
	}

	.side-section {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.side-label {
		padding: 0 10px 4px;
		color: var(--shell-faint);
		font-size: 11px;
		font-weight: var(--font-weight-medium);
		letter-spacing: 0.06em;
		line-height: 14px;
		text-transform: uppercase;
	}

	.side-item {
		display: flex;
		align-items: center;
		flex-shrink: 0;
		gap: 10px;
		height: 34px;
		padding: 0 10px;
		border-radius: 10px;
		color: var(--shell-strong);
		font-size: var(--text-14);
		line-height: 18px;
		text-decoration: none;
		/* Blueprint 23: the row answers the press itself, before the page loads. */
		-webkit-tap-highlight-color: transparent;
	}

	.side-item.top {
		height: 36px;
	}

	.side-icon {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 18px;
		height: 18px;
		color: var(--color-muted);
	}

	.side-text {
		flex: 1;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.side-count {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		min-width: 20px;
		height: 20px;
		padding: 0 6px;
		border-radius: var(--radius-pill);
		background: var(--shell-count);
		color: var(--color-text);
		font-size: 11px;
		font-weight: var(--font-weight-semibold);
		line-height: 14px;
	}

	.side-count.accent {
		background: var(--color-accent);
		color: var(--button-primary-ink);
	}

	.side-item:hover {
		background: color-mix(in oklab, var(--color-raised) 55%, transparent);
	}

	.side-item:active,
	.side-item[aria-current='page'] {
		background: var(--color-raised);
	}

	.side-item[aria-current='page'] {
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	.side-item[aria-current='page'] .side-icon {
		color: var(--color-accent);
	}

	.side-item:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: -2px;
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
		color: var(--shell-strong);
		font-size: var(--text-14);
		line-height: 18px;
	}

	.support-link {
		display: flex;
		align-items: center;
		gap: 8px;
		height: 40px;
		color: var(--shell-strong);
		font-size: var(--text-14);
		line-height: 18px;
		text-decoration: none;
	}

	.support-link[aria-current='page'] {
		color: var(--color-text);
		text-decoration: underline;
		text-underline-offset: 6px;
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
		overflow: hidden;
		width: 36px;
		height: 36px;
		background: var(--color-raised);
		color: var(--color-text);
		text-decoration: none;
	}

	.avatar-photo {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.avatar-initials {
		font-size: 13px;
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-16);
	}

	/* Paper NV01, simplified (Slice 30): tile, network name and a switch chevron;
	   one 56 px row whose items share a centre line with the bell and avatar. */
	.appbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		min-height: calc(56px + env(safe-area-inset-top));
		padding: env(safe-area-inset-top) 20px 0;
	}

	.ws-button {
		display: flex;
		align-items: center;
		flex: 0 1 auto;
		gap: 10px;
		min-width: 0;
		min-height: var(--hit-min);
		padding: 0;
		border: 0;
		border-radius: var(--radius-12);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		text-align: left;
		cursor: pointer;
	}

	.ws-button .brand-tile {
		width: 32px;
		height: 32px;
		border-radius: 9px;
	}

	.ws-button .ws-text {
		flex: 0 1 auto;
	}

	.ws-button .ws-name {
		font-size: var(--text-16);
		line-height: 20px;
	}

	.ws-button :global(.ws-chevron) {
		flex-shrink: 0;
		margin-left: -4px;
		color: var(--color-muted);
	}

	.appbar-actions {
		display: flex;
		align-items: center;
		flex-shrink: 0;
		gap: 4px;
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
		border: 1px solid var(--color-accent-edge);
		background: var(--shell-coral-tint);
	}

	.banner.update > :global(svg) {
		flex-shrink: 0;
		width: 18px;
		height: 18px;
		color: var(--color-accent-text);
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

	.banner.paused {
		align-items: flex-start;
		border: 1px solid color-mix(in oklab, var(--color-info) 20%, transparent);
		background: color-mix(in oklab, var(--color-info) 14%, var(--color-canvas));
	}

	.banner.paused > :global(svg) {
		flex-shrink: 0;
		color: var(--color-info);
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
		margin: 0;
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
		background-image: var(--button-primary-bg);
		box-shadow:
			#ffffff59 0px 1px 0px inset,
			var(--button-primary-glow) 0px 10px 28px -10px;
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

	/* ── Floating pill tab bar (mobile), Paper NV01/NV02 ──────────────── */

	.tabbar {
		position: fixed;
		right: 24px;
		bottom: calc(28px + env(safe-area-inset-bottom));
		left: 24px;
		z-index: 3;
		display: flex;
		align-items: center;
		justify-content: space-between;
		max-width: 440px;
		height: 64px;
		margin-inline: auto;
		padding: 0 6px;
		border: 1px solid var(--tab-edge);
		border-radius: 32px;
		background: var(--tab-bg);
		box-shadow: var(--tab-shadow);
		backdrop-filter: blur(24px) saturate(160%);
	}

	/* Inactive: the icon alone, in a 56 px slot (64 px with four tabs). */
	.tab {
		display: flex;
		align-items: center;
		justify-content: center;
		flex: 1 1 0;
		gap: 0;
		min-width: var(--hit-min);
		max-width: 56px;
		height: 52px;
		padding: 0;
		border-radius: 26px;
		color: var(--shell-strong);
		text-decoration: none;
		-webkit-tap-highlight-color: transparent;
		transition:
			background-color 200ms ease,
			color 200ms ease,
			gap 260ms cubic-bezier(0.2, 0.8, 0.2, 1),
			padding 260ms cubic-bezier(0.2, 0.8, 0.2, 1);
	}

	.tabbar[data-tabs='4'] .tab {
		max-width: 64px;
	}

	.tab-icon {
		position: relative;
		display: flex;
		flex-shrink: 0;
	}

	/* The current tab grows into a filled pill with its name. */
	.tab-label {
		max-width: 0;
		overflow: hidden;
		opacity: 0;
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
		white-space: nowrap;
		transition:
			max-width 260ms cubic-bezier(0.2, 0.8, 0.2, 1),
			opacity 160ms ease;
	}

	.tabbar .tab[aria-current='page'] {
		flex: 0 0 auto;
		gap: 8px;
		min-width: 56px;
		max-width: none;
		padding: 0 18px 0 14px;
		background: var(--color-accent);
		color: var(--button-primary-ink);
	}

	.tab[aria-current='page'] .tab-label {
		max-width: 120px;
		opacity: 1;
	}

	/* Blueprint 23: pressed at once; the current state follows the tap. */
	.tab:active:not([aria-current='page']) {
		background: var(--shell-coral-tint);
	}

	.tab:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 2px;
	}

	.tab-dot {
		position: absolute;
		top: 0;
		right: -5px;
		width: 9px;
		height: 9px;
		border: 2px solid var(--shell-active);
		border-radius: var(--radius-pill);
		background: var(--color-accent);
	}

	@media (prefers-reduced-motion: reduce) {
		.tab,
		.tab-label {
			transition: none;
		}
	}

	/*
	 * Narrow phones (P-06: checked at 320 px). Below 380 px the bar comes closer
	 * to the edges; below 350 px five tabs leave no room for a label, so the
	 * current one stays a filled pill with its icon (its name is still read out).
	 */
	@media (max-width: 379px) {
		.tabbar {
			right: 12px;
			left: 12px;
		}
	}

	@media (max-width: 349px) {
		.tabbar[data-tabs='5'] .tab[aria-current='page'] {
			gap: 0;
			padding: 0;
		}

		.tabbar[data-tabs='5'] .tab[aria-current='page'] .tab-label {
			max-width: 0;
			opacity: 0;
		}
	}

	/*
	 * Blueprint 23: the page swap. Only the page area takes part, and only
	 * while a swap runs (data-page-swap on <html>, set in onNavigate), so the
	 * page keeps its normal stacking the rest of the time.
	 */
	:global(html[data-page-swap]) .content {
		view-transition-name: ew-page;
	}

	:global(::view-transition-old(root)),
	:global(::view-transition-new(root)) {
		animation: none;
	}

	:global(::view-transition-old(ew-page)) {
		animation: 90ms ease-out both ew-page-out;
	}

	:global(::view-transition-new(ew-page)) {
		animation: 180ms ease-out both ew-page-in;
	}

	@keyframes -global-ew-page-out {
		to {
			opacity: 0;
		}
	}

	@keyframes -global-ew-page-in {
		from {
			opacity: 0;
			transform: translateY(6px);
		}
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

	/* Paper App v4 NB01 notifications panel. */
	:global(.popover.notifications) {
		width: 420px;
		max-height: min(640px, calc(100vh - 96px));
		border-color: #ffffff1f;
		border-radius: 20px;
		background: #1a1d1ef2;
		box-shadow: #000000d9 0px 30px 70px -20px;
		backdrop-filter: blur(20px);
	}

	:global([data-theme='light'] .popover.notifications) {
		border-color: var(--color-border);
		background: #fffffff2;
		box-shadow: #2126282e 0px 30px 70px -20px;
	}

	:global(.bell-dot) {
		position: absolute;
		top: 9px;
		right: 10px;
		width: 8px;
		height: 8px;
		border: 2px solid var(--color-canvas);
		border-radius: var(--radius-pill);
		background: var(--color-accent);
	}

	:global(.pop-head) {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 18px 20px 12px;
	}

	:global(.pop-head .pop-title) {
		padding: 0;
		font-size: var(--text-16);
	}

	:global(.pop-link) {
		border: 0;
		background: none;
		color: var(--color-accent-text);
		font: inherit;
		font-size: 13px;
		line-height: var(--leading-16);
		cursor: pointer;
	}

	:global(.pop-tabs) {
		display: flex;
		gap: 6px;
		padding: 0 20px 12px;
		border-bottom: 1px solid #ffffff0f;
	}

	:global([data-theme='light'] .pop-tabs) {
		border-bottom-color: var(--color-border);
	}

	:global(.pop-tab) {
		display: flex;
		align-items: center;
		height: 30px;
		padding: 0 12px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--shell-strong);
		font: inherit;
		font-size: var(--text-12);
		line-height: var(--leading-16);
		cursor: pointer;
	}

	:global(.pop-tab[aria-pressed='true']) {
		border-color: var(--color-text);
		background: var(--color-text);
		color: var(--color-canvas);
		font-weight: var(--font-weight-semibold);
	}

	:global(.pop-scroll) {
		flex: 1 1 auto;
		min-height: 0;
		overflow-y: auto;
	}

	:global(.pop-note) {
		padding: 20px;
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	:global(.pop-all) {
		display: flex;
		justify-content: center;
		padding: 14px 20px;
		border-top: 1px solid #ffffff0f;
		color: var(--color-text);
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-16);
		text-decoration: none;
	}

	:global([data-theme='light'] .pop-all) {
		border-top-color: var(--color-border);
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
		background: var(--color-accent-subtle);
		color: var(--color-accent-text);
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

		/* Paper NV03: 64 px, the same line as the switcher block. */
		.topbar {
			display: flex;
			align-items: center;
			gap: 20px;
			flex-shrink: 0;
			height: var(--shell-header);
			padding: 0 40px;
			border-bottom: 1px solid var(--shell-line);
		}

		.topbar :global(.bell) {
			width: 36px;
			height: 36px;
		}

		.topbar :global(.bell-dot) {
			top: 6px;
			right: 7px;
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
