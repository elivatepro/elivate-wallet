<!--
	Notifications (mobile pushed page; also "See all" on desktop): Paper App v1
	S04 and App v4 NB01 (mobile). Needs your action / New / Earlier cards,
	"Read all", "You're all caught up" at the end; the empty state is v3 H07.
-->
<script lang="ts">
	import { getContext, onMount } from 'svelte';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import type { Bell } from '#lib/client/bell.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import NotificationList from '#lib/ui/app/NotificationList.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';

	const bell = getContext<Bell>('bell');
	const shell = getContext<Shell>('shell');

	onMount(() => {
		void bell.load('all');
	});

	const list = $derived(bell.list.kind === 'ready' ? bell.list : null);
	const empty = $derived(!!list && list.actions.length === 0 && list.items.length === 0);
</script>

<svelte:head><title>Notifications · Elivate Wallet</title></svelte:head>

<header class="navbar">
	<a class="back" href="/app" aria-label="Back to Home"
		><ChevronLeft size={22} strokeWidth={2} aria-hidden="true" /></a
	>
	<h1>Notifications</h1>
	{#if bell.unread > 0}
		<button type="button" class="read-all" onclick={() => bell.markAll()}>Read all</button>
	{:else}
		<span class="spacer" aria-hidden="true"></span>
	{/if}
</header>

<div class="desk-head">
	<h1 class="desk-title">Notifications</h1>
	{#if bell.unread > 0}
		<button type="button" class="read-all" onclick={() => bell.markAll()}>Mark all as read</button>
	{/if}
</div>

{#if empty}
	<section class="empty">
		<RootImage pose="notifications" class="empty-root" sizes="210px" eager />
		<p class="title">No notifications yet</p>
		<p class="lead">Updates about your money show up here.</p>
	</section>
{:else if list}
	<NotificationList {bell} variant="page" hide={shell.hideAmounts} />
	{#if list.nextCursor}
		<button type="button" class="more" disabled={bell.more} onclick={() => bell.loadMore()}>
			{bell.more ? 'Loading…' : 'Show earlier'}
		</button>
	{:else}
		<section class="caught-up">
			<RootImage pose="notifications" class="caught-root" sizes="96px" />
			<p>You’re all caught up.</p>
		</section>
	{/if}
{:else if bell.list.kind === 'error'}
	<p class="note" role="alert">Couldn’t load notifications.</p>
	<button type="button" class="more" onclick={() => bell.load('all')}>Try again</button>
{:else}
	<p class="note">Loading…</p>
{/if}

<style>
	.navbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: calc(4px + env(safe-area-inset-top)) 16px 8px 12px;
	}

	.back,
	.spacer {
		display: flex;
		align-items: center;
		justify-content: center;
		width: var(--hit-min);
		height: var(--hit-min);
		color: var(--color-text);
	}

	h1 {
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.read-all {
		min-width: var(--hit-min);
		min-height: var(--hit-min);
		border: 0;
		background: none;
		color: var(--color-accent-text);
		font: inherit;
		font-size: 13px;
		line-height: var(--leading-16);
		cursor: pointer;
	}

	.desk-head {
		display: none;
	}

	.empty {
		display: flex;
		flex: 1;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 8px;
		padding: 0 32px 120px;
		text-align: center;
	}

	.empty :global(.empty-root) {
		width: 210px;
		height: 280px;
	}

	.title {
		padding-top: 12px;
		font-size: 22px;
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.02em;
		line-height: 28px;
	}

	.lead,
	.note {
		color: var(--color-muted);
		font-size: 15px;
		line-height: 22px;
	}

	.note {
		padding: 24px 20px;
	}

	.caught-up {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 12px;
		padding: 40px 32px 120px;
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.caught-up :global(.caught-root) {
		width: 96px;
		height: 128px;
	}

	.more {
		align-self: center;
		min-height: var(--hit-min);
		margin: 12px auto 120px;
		padding: 0 20px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: var(--text-14);
		cursor: pointer;
	}

	@media (min-width: 1024px) {
		.navbar {
			display: none;
		}

		.desk-head {
			display: flex;
			align-items: center;
			justify-content: space-between;
			max-width: 720px;
			padding: 32px 32px 8px;
		}

		.desk-title {
			font-size: var(--text-24);
			font-weight: var(--font-weight-semibold);
			letter-spacing: var(--tracking-display);
			line-height: var(--leading-32);
		}

		.empty {
			padding: 48px 32px;
		}

		:global(.list.page) {
			max-width: 720px;
			padding: 8px 32px;
		}
	}
</style>
