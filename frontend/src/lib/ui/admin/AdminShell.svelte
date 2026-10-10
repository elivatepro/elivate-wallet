<!--
	Admin shell, Paper "Admin — Screens v1" (A03…) with the approved draft
	sidebar (A17d…): Overview, Search · Founder applications (A22d), Networks,
	Accounts, NIN reviews · Kill switches, Audit, Backups & restores, Failed
	emails, Admins. Top bar: page
	title, the live step-up state and the account menu (sign out). Mobile:
	app bar and floating bottom tabs (Overview, Search, Networks, More).
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import LayoutGrid from '@lucide/svelte/icons/layout-grid';
	import Search from '@lucide/svelte/icons/search';
	import Building from '@lucide/svelte/icons/building-2';
	import UserRound from '@lucide/svelte/icons/user-round';
	import IdCard from '@lucide/svelte/icons/id-card';
	import ClipboardList from '@lucide/svelte/icons/clipboard-list';
	import Flag from '@lucide/svelte/icons/flag';
	import FileText from '@lucide/svelte/icons/file-text';
	import Database from '@lucide/svelte/icons/database';
	import Mail from '@lucide/svelte/icons/mail';
	import Shield from '@lucide/svelte/icons/shield';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import LogOut from '@lucide/svelte/icons/log-out';
	import { initials } from '#lib/admin.js';

	let {
		path,
		title,
		name,
		uid,
		stepUpUntil,
		children
	}: {
		path: string;
		title: string;
		name: string | null;
		uid: string;
		/** "14:05" while a step-up window is open, else null. */
		stepUpUntil: string | null;
		children: Snippet;
	} = $props();

	const directory = [
		{ href: '/admin/applications', label: 'Founder applications', icon: ClipboardList },
		{ href: '/admin/networks', label: 'Networks', icon: Building },
		{ href: '/admin/accounts', label: 'Accounts', icon: UserRound },
		{ href: '/admin/nin', label: 'NIN reviews', icon: IdCard }
	];
	const controls = [
		{ href: '/admin/switches', label: 'Kill switches', icon: Flag },
		{ href: '/admin/audit', label: 'Audit', icon: FileText },
		{ href: '/admin/backups', label: 'Backups & restores', icon: Database },
		{ href: '/admin/emails', label: 'Failed emails', icon: Mail },
		{ href: '/admin/admins', label: 'Admins', icon: Shield }
	];

	const active = (href: string) =>
		href === '/admin' ? path === '/admin' : path === href || path.startsWith(`${href}/`);
	const moreActive = $derived(
		[...directory, ...controls].some(
			(item) => item.href !== '/admin/networks' && active(item.href)
		) || active('/admin/more')
	);
</script>

<div class="shell">
	<aside class="sidebar" aria-label="Admin">
		<div class="brand">
			<div class="brand-card">
				<span class="brand-tile" aria-hidden="true"><img src="/icons/mark.svg" alt="" /></span>
				<span class="brand-text">
					<strong>Elivate Admin</strong>
					<span class="chip"><span class="dot"></span>Platform</span>
				</span>
			</div>
		</div>
		<nav>
			<a class="item" href="/admin" aria-current={active('/admin') ? 'page' : undefined}>
				<LayoutGrid size={18} aria-hidden="true" />Overview
			</a>
			<a
				class="item"
				href="/admin/search"
				aria-current={active('/admin/search') ? 'page' : undefined}
			>
				<Search size={18} aria-hidden="true" />Search
			</a>
			<p class="group">Directory</p>
			{#each directory as item (item.href)}
				<a class="item" href={item.href} aria-current={active(item.href) ? 'page' : undefined}>
					<item.icon size={18} aria-hidden="true" />{item.label}
				</a>
			{/each}
			<p class="group">Controls</p>
			{#each controls as item (item.href)}
				<a class="item" href={item.href} aria-current={active(item.href) ? 'page' : undefined}>
					<item.icon size={18} aria-hidden="true" />{item.label}
				</a>
			{/each}
		</nav>
		<footer>
			<span>admin.elivatewallet.com</span>
		</footer>
	</aside>

	<div class="main">
		<header class="topbar">
			<h1 class="crumb">{title}</h1>
			<span class="stepup" class:open={stepUpUntil !== null}>
				<Shield size={14} aria-hidden="true" />
				{stepUpUntil ? `Elevated until ${stepUpUntil}` : 'Not elevated'}
			</span>
			<details class="account">
				<summary aria-label="Account menu">{initials(name)}</summary>
				<div class="menu">
					<p><strong>{name ?? uid}</strong><span>{uid}</span></p>
					<form method="POST" action="/admin/sign-out">
						<button type="submit"><LogOut size={16} aria-hidden="true" />Sign out</button>
					</form>
				</div>
			</details>
		</header>
		<main class="content">
			{@render children()}
		</main>
	</div>

	<nav class="tabs" aria-label="Admin sections">
		<a href="/admin" aria-current={active('/admin') ? 'page' : undefined}>
			<LayoutGrid size={20} aria-hidden="true" /><span>Overview</span>
		</a>
		<a href="/admin/search" aria-current={active('/admin/search') ? 'page' : undefined}>
			<Search size={20} aria-hidden="true" /><span>Search</span>
		</a>
		<a href="/admin/networks" aria-current={active('/admin/networks') ? 'page' : undefined}>
			<Building size={20} aria-hidden="true" /><span>Networks</span>
		</a>
		<a href="/admin/more" aria-current={moreActive ? 'page' : undefined}>
			<Ellipsis size={20} aria-hidden="true" /><span>More</span>
		</a>
	</nav>
</div>

<style>
	.shell {
		display: flex;
		min-height: 100dvh;
		background: var(--color-canvas);
		color: var(--color-text);
	}
	.sidebar {
		position: sticky;
		top: 0;
		display: flex;
		flex-direction: column;
		flex-shrink: 0;
		width: 260px;
		height: 100dvh;
		background: color-mix(in oklab, var(--color-canvas) 80%, #000);
		border-right: 1px solid color-mix(in oklab, var(--color-border) 50%, transparent);
	}
	.brand {
		padding: 12px 12px 10px;
		border-bottom: 1px solid color-mix(in oklab, var(--color-border) 50%, transparent);
	}
	.brand-card {
		display: flex;
		align-items: center;
		gap: 10px;
		height: 52px;
		padding: 0 10px 0 7px;
		background: var(--color-surface);
		border: 1px solid color-mix(in oklab, var(--color-border) 70%, transparent);
		border-radius: 14px;
	}
	.brand-tile {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 38px;
		height: 38px;
		border-radius: 10px;
		background: var(--color-accent-subtle);
		border: 1px solid color-mix(in oklab, var(--color-accent) 20%, transparent);
	}
	.brand-tile img {
		width: 20px;
		height: 20px;
	}
	.brand-text {
		display: flex;
		flex-direction: column;
		gap: 3px;
	}
	.brand-text strong {
		font-size: 14px;
		font-weight: 600;
		line-height: 18px;
	}
	.chip {
		display: inline-flex;
		align-items: center;
		align-self: flex-start;
		gap: 5px;
		padding: 1px 7px;
		border: 1px solid color-mix(in oklab, var(--color-accent) 30%, transparent);
		border-radius: 999px;
		font-family: var(--font-mono);
		font-size: 10px;
		letter-spacing: 0.08em;
		line-height: 15px;
		text-transform: uppercase;
		color: var(--color-accent-text);
	}
	.dot {
		width: 5px;
		height: 5px;
		border-radius: 999px;
		background: var(--color-accent);
	}
	.sidebar nav {
		display: flex;
		flex: 1 1 auto;
		flex-direction: column;
		gap: 2px;
		padding: 14px 12px;
		overflow-y: auto;
	}
	.group {
		margin: 0;
		padding: 18px 12px 6px;
		font-size: 12px;
		line-height: 16px;
		color: var(--color-muted);
	}
	.item {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 38px;
		padding: 0 12px;
		border-radius: 9px;
		font-size: 14px;
		line-height: 18px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
		text-decoration: none;
	}
	.item :global(svg) {
		color: var(--color-muted);
	}
	.item:hover {
		background: color-mix(in oklab, var(--color-raised) 50%, transparent);
	}
	.item[aria-current='page'] {
		background: var(--color-raised);
		font-weight: 500;
		color: var(--color-text);
	}
	.item[aria-current='page'] :global(svg) {
		color: var(--color-accent);
	}
	.item:focus-visible,
	.tabs a:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 1px;
	}
	.sidebar footer {
		padding: 14px 16px;
		border-top: 1px solid color-mix(in oklab, var(--color-border) 50%, transparent);
		font-family: var(--font-mono);
		font-size: 11px;
		letter-spacing: 0.04em;
		color: var(--color-muted);
	}
	.main {
		display: flex;
		flex: 1 1 auto;
		flex-direction: column;
		min-width: 0;
	}
	.topbar {
		position: sticky;
		top: 0;
		z-index: 10;
		display: flex;
		align-items: center;
		gap: 12px;
		height: 64px;
		padding: 0 28px 0 40px;
		background: color-mix(in oklab, var(--color-canvas) 92%, transparent);
		backdrop-filter: blur(8px);
		border-bottom: 1px solid color-mix(in oklab, var(--color-border) 50%, transparent);
	}
	.crumb {
		flex: 1 1 auto;
		margin: 0;
		font-size: 14px;
		font-weight: 400;
		line-height: 18px;
		color: var(--color-muted);
	}
	.stepup {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		height: 32px;
		padding: 0 12px;
		border: 1px solid color-mix(in oklab, var(--color-border) 70%, transparent);
		border-radius: 999px;
		background: var(--color-surface);
		font-size: 13px;
		color: color-mix(in oklab, var(--color-text) 85%, var(--color-muted));
	}
	.stepup.open {
		border-color: color-mix(in oklab, var(--color-success) 40%, transparent);
		color: var(--color-success);
	}
	.account {
		position: relative;
	}
	.account summary {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 36px;
		height: 36px;
		border-radius: 999px;
		background: var(--color-raised);
		font-size: 13px;
		font-weight: 600;
		list-style: none;
		cursor: pointer;
	}
	.account summary::-webkit-details-marker {
		display: none;
	}
	.menu {
		position: absolute;
		right: 0;
		top: 44px;
		width: 220px;
		padding: 8px;
		background: var(--color-surface);
		border: 1px solid var(--color-border);
		border-radius: 14px;
		box-shadow: 0 20px 50px -20px #000a;
	}
	.menu p {
		display: flex;
		flex-direction: column;
		gap: 2px;
		margin: 0;
		padding: 8px 10px 10px;
		font-size: 13px;
	}
	.menu p span {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--color-muted);
	}
	.menu button {
		display: flex;
		align-items: center;
		gap: 10px;
		width: 100%;
		min-height: 40px;
		padding: 0 10px;
		border: 0;
		border-radius: 9px;
		background: transparent;
		font: inherit;
		font-size: 14px;
		color: var(--color-text);
		cursor: pointer;
	}
	.menu button:hover {
		background: var(--color-raised);
	}
	.content {
		display: flex;
		flex-direction: column;
		gap: 32px;
		width: 100%;
		max-width: 1260px;
		padding: 32px 40px 48px;
	}
	.tabs {
		display: none;
	}
	@media (max-width: 1023px) {
		.sidebar {
			display: none;
		}
		.topbar {
			padding: 0 16px;
		}
		.stepup {
			display: none;
		}
		.crumb {
			font-size: 17px;
			font-weight: 600;
			color: var(--color-text);
		}
		.content {
			padding: 16px 16px 120px;
		}
		.tabs {
			position: fixed;
			left: 16px;
			right: 16px;
			bottom: 16px;
			z-index: 20;
			display: flex;
			justify-content: space-around;
			gap: 4px;
			padding: 8px;
			background: color-mix(in oklab, var(--color-surface) 94%, transparent);
			backdrop-filter: blur(10px);
			border: 1px solid color-mix(in oklab, var(--color-border) 70%, transparent);
			border-radius: 24px;
			box-shadow: 0 20px 40px -20px #000a;
		}
		.tabs a {
			display: flex;
			flex: 1 1 0;
			flex-direction: column;
			align-items: center;
			gap: 4px;
			min-height: 52px;
			padding: 6px 0;
			border-radius: 16px;
			font-size: 11px;
			color: var(--color-muted);
			text-decoration: none;
		}
		.tabs a[aria-current='page'] {
			background: var(--color-raised);
			color: var(--color-text);
		}
		.tabs a[aria-current='page'] :global(svg) {
			color: var(--color-accent);
		}
	}
</style>
