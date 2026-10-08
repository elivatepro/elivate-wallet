<!--
	More tab (mobile account menu), Paper "App — Screens v3" H05 mobile. Only
	what exists is listed: Wallet rows, Security & PIN, Language, Timezone and
	Support arrive with their screens. No person name exists yet, so the profile
	card shows role, network and the Elivate ID.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import Bell from '@lucide/svelte/icons/bell';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import ChevronsUpDown from '@lucide/svelte/icons/chevrons-up-down';
	import EyeOff from '@lucide/svelte/icons/eye-off';
	import LogOut from '@lucide/svelte/icons/log-out';
	import Moon from '@lucide/svelte/icons/moon';
	import UserRound from '@lucide/svelte/icons/user-round';
	import { THEME_LABELS, type Appearance } from '#lib/client/appearance.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import { THEMES } from '#lib/theme.js';

	const shell = getContext<Shell>('shell');
	const appearance = getContext<Appearance>('appearance');
	const signOut = getContext<() => void>('signOut');

	const summary = $derived(
		shell.state.kind === 'ready' || shell.state.kind === 'offline' ? shell.state.summary : null
	);
	const uid = $derived(shell.state.kind === 'ready' ? shell.state.view.state.uid : null);
	const person = $derived(shell.state.kind === 'ready' ? shell.state.view.profile : null);

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

<div class="profile">
	<span class="profile-avatar" aria-hidden="true">
		{#if person?.hasPhoto}<img src="/api/profile/photo" alt="" />{:else}<UserRound
				size={24}
				strokeWidth={1.6}
			/>{/if}
	</span>
	<span class="profile-text">
		{#if person?.name}<span class="profile-name">{person.name}</span>{/if}
		{#if summary}<span class={person?.name ? 'profile-uid' : 'profile-name'}
				>{ROLE_LABELS[summary.role]}{summary.officeName ? ` · ${summary.officeName}` : ''}</span
			>{/if}
		{#if uid}<span class="profile-uid">{uid}</span>{/if}
	</span>
</div>

<a class="workspace" href="/workspaces?switch">
	<span class="brand-tile" aria-hidden="true"><img src="/icons/mark.svg" alt="" /></span>
	<span class="ws-text">
		<span class="ws-name">{summary?.officeName ?? summary?.tenantName ?? ''}</span>
		{#if summary}<span class="ws-chip">{ROLE_LABELS[summary.role]}</span>{/if}
	</span>
	<ChevronsUpDown size={14} strokeWidth={1.6} aria-hidden="true" />
	<span class="visually-hidden">Switch workspace</span>
</a>

<section class="group" aria-labelledby="account-label">
	<h2 class="eyebrow" id="account-label">Account</h2>
	<div class="card">
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

	.profile,
	.workspace,
	.card {
		border: 1px solid #ffffff14;
		background: var(--color-surface);
	}

	:global([data-theme='light']) .profile,
	:global([data-theme='light']) .workspace,
	:global([data-theme='light']) .card {
		border-color: var(--color-border);
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
		border-radius: var(--radius-pill);
		background: #3a251f;
		color: #ff9c77;
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
		height: 60px;
		padding: 0 16px 0 10px;
		border-color: #2a2f31;
		border-radius: 18px;
		box-shadow: #ffffff0a 0px 1px 0px inset;
		color: var(--color-text);
		text-decoration: none;
	}

	.workspace > :global(svg) {
		flex-shrink: 0;
		color: #d5dadb;
	}

	.brand-tile {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 38px;
		height: 38px;
		border: 1px solid #ff7f4f33;
		border-radius: var(--radius-pill);
		background: #2a1e1a;
	}

	.brand-tile img {
		width: 18px;
		height: 18px;
	}

	.ws-text {
		display: flex;
		flex: 1;
		flex-direction: column;
		align-items: flex-start;
		gap: 2px;
		min-width: 0;
	}

	.ws-name {
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
	}

	.ws-chip {
		padding: 0 6px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: #d5dadb;
		font-size: 10px;
		font-weight: var(--font-weight-medium);
		line-height: 14px;
	}

	:global([data-theme='light']) .ws-chip,
	:global([data-theme='light']) .workspace > :global(svg) {
		color: var(--color-text);
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
		font-size: var(--text-12);
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.08em;
		line-height: var(--leading-16);
		text-transform: uppercase;
	}

	.card {
		display: flex;
		flex-direction: column;
		overflow: clip;
		border-radius: var(--radius-16);
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
		cursor: pointer;
	}

	.row + .row {
		border-top: 1px solid #ffffff0a;
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
