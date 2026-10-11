<!--
	More tab (mobile account menu), Paper "App — Screens v3" H05 mobile. Only
	what exists is listed: Wallet rows, Security & PIN, Language and Timezone
	arrive with their screens. Blueprint 17: Branding & settings and Support. No person name exists yet, so the profile
	card shows role, network and the Elivate ID.
-->
<script lang="ts">
	import { getContext, type Snippet } from 'svelte';
	import Bell from '@lucide/svelte/icons/bell';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import ChevronsUpDown from '@lucide/svelte/icons/chevrons-up-down';
	import EyeOff from '@lucide/svelte/icons/eye-off';
	import CircleHelp from '@lucide/svelte/icons/circle-help';
	import LogOut from '@lucide/svelte/icons/log-out';
	import Moon from '@lucide/svelte/icons/moon';
	import Search from '@lucide/svelte/icons/search';
	import UserRound from '@lucide/svelte/icons/user-round';
	import UserCog from '@lucide/svelte/icons/user-cog';
	import { goto } from '$app/navigation';
	import { THEME_LABELS, type Appearance } from '#lib/client/appearance.svelte.js';
	import { profilePhotoSrc } from '#lib/client/photo.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import type { NavModel } from '#lib/nav.js';
	import { THEMES } from '#lib/theme.js';
	import NavIcon from '#lib/ui/app/NavIcon.svelte';

	const shell = getContext<Shell>('shell');
	const appearance = getContext<Appearance>('appearance');
	const signOut = getContext<() => void>('signOut');
	const nav = getContext<() => NavModel>('nav');
	const openSearch = getContext<(() => void) | undefined>('openSearch');
	const brandTile = getContext<(() => Snippet) | undefined>('brandTile');

	const summary = $derived(
		shell.state.kind === 'ready' || shell.state.kind === 'offline' ? shell.state.summary : null
	);
	const uid = $derived(shell.state.kind === 'ready' ? shell.state.view.state.uid : null);
	const person = $derived(shell.state.kind === 'ready' ? shell.state.view.profile : null);
	const photoSrc = $derived(profilePhotoSrc(person));
	let brokenPhoto = $state<string | null>(null);
	/**
	 * Blueprint 25: the sidebar's sections (#lib/nav.ts), without what the tab
	 * bar already holds (Home, Activity); everything else is listed here.
	 */
	const tabs = $derived(new Set(['home', ...nav().tabs.map((t) => t.id)]));
	const sections = $derived(
		nav()
			.sections.map((section) => ({
				...section,
				items: section.items.filter((item) => !tabs.has(item.id))
			}))
			.filter((section) => section.items.length > 0)
	);
	const scopeLine = $derived(
		summary ? `${ROLE_LABELS[summary.role]} · ${summary.officeName ?? 'whole network'}` : ''
	);

	function nextTheme() {
		const next = THEMES[(THEMES.indexOf(appearance.theme) + 1) % THEMES.length] ?? 'dark';
		appearance.set(next);
	}
</script>

<svelte:head><title>More · Elivate Wallet</title></svelte:head>

<header class="bar">
	<h1>More</h1>
	<a class="bell" href="/app/notifications" aria-label="Notifications">
		<Bell size={19} strokeWidth={1.5} aria-hidden="true" />
	</a>
</header>

{#if openSearch && shell.state.kind === 'ready'}
	<button type="button" class="search" onclick={openSearch} aria-haspopup="dialog">
		<Search size={16} strokeWidth={2} aria-hidden="true" />
		<span>Quick search…</span>
	</button>
{/if}

<div class="profile">
	<span class="profile-avatar" aria-hidden="true">
		{#if photoSrc && photoSrc !== brokenPhoto}<img
				src={photoSrc}
				alt=""
				onerror={() => (brokenPhoto = photoSrc)}
			/>{:else}<UserRound size={24} strokeWidth={1.6} />{/if}
	</span>
	<span class="profile-text">
		{#if person?.name}<span class="profile-name">{person.name}</span>{/if}
		{#if summary}<span class={person?.name ? 'profile-sub' : 'profile-name'}
				>{ROLE_LABELS[summary.role]}{summary.officeName ? ` · ${summary.officeName}` : ''}</span
			>{/if}
		{#if uid}<span class="profile-uid">{uid}</span>{/if}
	</span>
</div>

<!-- Paper NV01's app bar tile and wording: the network, then "role · scope". -->
<button type="button" class="workspace" onclick={() => goto('/workspaces?switch')}>
	{#if brandTile}<span class="tile">{@render brandTile()()}</span>{/if}
	<span class="ws-text">
		<span class="ws-name">{summary?.tenantName ?? ''}</span>
		{#if summary}<span class="ws-sub">{scopeLine}</span>{/if}
	</span>
	<ChevronsUpDown size={16} strokeWidth={2} aria-hidden="true" />
	<span class="visually-hidden">Switch workspace</span>
</button>

{#each sections as section (section.id)}
	<section class="group" aria-labelledby="more-{section.id}">
		<h2 class="eyebrow" id="more-{section.id}">{section.label ?? 'Go to'}</h2>
		<div class="card">
			{#each section.items as item (item.id)}
				<a class="row" href={item.href}>
					<span class="row-icon"><NavIcon name={item.icon} size={20} strokeWidth={1.8} /></span>
					<span class="label">{item.label}</span>
					{#if item.count}<span class="count" class:accent={item.accent}
							>{item.count}<span class="visually-hidden"> waiting</span></span
						>{/if}
					<ChevronRight size={16} strokeWidth={2} class="chev" aria-hidden="true" />
				</a>
			{/each}
		</div>
	</section>
{/each}

<section class="group" aria-labelledby="account-label">
	<h2 class="eyebrow" id="account-label">Account</h2>
	<div class="card">
		<a class="row" href="/app/account">
			<UserCog size={20} strokeWidth={1.8} aria-hidden="true" />
			<span class="label">Profile & security</span>
			<ChevronRight size={16} strokeWidth={2} class="chev" aria-hidden="true" />
		</a>
		<a class="row" href="/app/support">
			<CircleHelp size={20} strokeWidth={1.8} aria-hidden="true" />
			<span class="label">Support</span>
			<ChevronRight size={16} strokeWidth={2} class="chev" aria-hidden="true" />
		</a>
		<button type="button" class="row" onclick={nextTheme}>
			<Moon size={20} strokeWidth={1.8} aria-hidden="true" />
			<span class="label">Appearance</span>
			<span class="value">{THEME_LABELS[appearance.theme]}</span>
			<ChevronRight size={16} strokeWidth={2} class="chev" aria-hidden="true" />
		</button>
		<label class="row">
			<EyeOff size={20} strokeWidth={1.8} aria-hidden="true" />
			<span class="label">Hide amounts</span>
			<input
				type="checkbox"
				class="switch"
				role="switch"
				checked={shell.hideAmounts}
				onchange={(event) => shell.setHideAmounts(event.currentTarget.checked)}
			/>
		</label>
	</div>
</section>

<div class="card">
	<button type="button" class="row danger" disabled={!shell.online} onclick={signOut}>
		<LogOut size={20} strokeWidth={1.8} aria-hidden="true" />
		<span class="label">Sign out</span>
	</button>
</div>

<style>
	.bar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding-top: env(safe-area-inset-top);
	}

	h1 {
		font-size: 28px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.02em;
		line-height: 36px;
	}

	/* Blueprint 25: the new design language (Paper "Navigation v5"): 18 px
	   cards on the surface, one quiet edge, mono eyebrows. */
	.profile,
	.workspace,
	.card,
	.search {
		border: 1px solid var(--shell-edge, var(--color-border));
		background: var(--color-surface);
	}

	.search {
		display: flex;
		align-items: center;
		gap: 10px;
		width: 100%;
		height: 46px;
		padding: 0 16px;
		border-radius: var(--radius-pill);
		color: var(--color-muted);
		font: inherit;
		font-size: var(--text-14);
		line-height: 18px;
		text-align: left;
		cursor: pointer;
	}

	.profile {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 16px;
		border-radius: 18px;
	}

	.profile-avatar {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 52px;
		height: 52px;
		overflow: hidden;
		border-radius: var(--radius-pill);
		background: var(--color-accent-subtle);
		color: var(--color-accent-text);
	}

	.profile-text {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.profile-name {
		font-size: var(--text-16);
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-20);
	}

	.profile-sub {
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	.profile-uid {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		letter-spacing: var(--tracking-label);
		line-height: var(--leading-16);
	}

	.workspace {
		display: flex;
		align-items: center;
		gap: 10px;
		width: 100%;
		height: 64px;
		padding: 0 16px 0 12px;
		border-radius: 18px;
		color: var(--color-text);
		font: inherit;
		text-align: left;
		cursor: pointer;
		-webkit-tap-highlight-color: transparent;
	}

	.workspace:active {
		background: var(--color-raised);
	}

	.workspace > :global(svg) {
		flex-shrink: 0;
		color: var(--color-muted);
	}

	.tile {
		display: flex;
		flex-shrink: 0;
	}

	.tile :global(.brand-tile) {
		width: 36px;
		height: 36px;
		border-radius: 10px;
	}

	.ws-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.ws-name,
	.ws-sub {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.ws-name {
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
	}

	.ws-sub {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.group {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding-top: 6px;
	}

	.eyebrow {
		padding-left: 4px;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.08em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.card {
		display: flex;
		flex-direction: column;
		overflow: clip;
		border-radius: 18px;
	}

	.row-icon {
		display: flex;
		flex-shrink: 0;
		color: var(--shell-strong, var(--color-text));
	}

	.count {
		flex-shrink: 0;
		padding: 2px 9px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--color-text);
		font-size: var(--text-12);
		font-weight: var(--font-weight-semibold);
		line-height: 16px;
	}

	.count.accent {
		background: var(--color-accent);
		color: var(--button-primary-ink);
	}

	.row {
		display: flex;
		align-items: center;
		gap: 14px;
		width: 100%;
		height: 54px;
		padding: 0 16px;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font-size: 15px;
		line-height: 18px;
		text-align: left;
		text-decoration: none;
		cursor: pointer;
	}

	/* Blueprint 23: the row answers the press at once. */
	.row {
		-webkit-tap-highlight-color: transparent;
	}

	.row:active {
		background: var(--color-raised);
	}

	.row + .row {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 4%, transparent);
	}

	.row > :global(svg:first-child) {
		flex-shrink: 0;
		color: #d5dadb;
	}

	:global([data-theme='light']) .row > :global(svg:first-child) {
		color: var(--color-text);
	}

	.label {
		flex: 1;
	}

	.value {
		color: var(--color-muted);
		font-size: 13px;
		line-height: var(--leading-16);
	}

	.row :global(.chev) {
		flex-shrink: 0;
		color: #7d8588;
	}

	.row.danger,
	.row.danger > :global(svg:first-child) {
		color: var(--color-danger);
	}

	.row:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	.switch {
		appearance: none;
		position: relative;
		flex-shrink: 0;
		width: 44px;
		height: 26px;
		margin: 0;
		border-radius: var(--radius-pill);
		background: var(--color-border);
		cursor: pointer;
	}

	.switch::after {
		content: '';
		position: absolute;
		top: 3px;
		left: 3px;
		width: 20px;
		height: 20px;
		border-radius: var(--radius-pill);
		background: var(--color-muted);
		transition: transform 120ms ease;
	}

	.switch:checked {
		background: var(--color-accent);
	}

	.switch:checked::after {
		transform: translateX(18px);
		background: var(--button-primary-ink);
	}

	@media (prefers-reduced-motion: reduce) {
		.switch::after {
			transition: none;
		}
	}

	@media (min-width: 1024px) {
		.bar {
			display: none;
		}
	}

	.profile-avatar img {
		width: 100%;
		height: 100%;
		border-radius: inherit;
		object-fit: cover;
	}
</style>
