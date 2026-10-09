<!--
	Bell items (Blueprint 13): Paper App v4 NB01 (Needs your action / Earlier)
	and App v1 S01/S04 (New / Earlier). `popover` is the desktop panel's flat
	list; `page` is the mobile Notifications page's grouped cards. Tapping an
	item marks it read and follows its in-app link.
-->
<script lang="ts">
	import ArrowDown from '@lucide/svelte/icons/arrow-down';
	import ArrowLeftRight from '@lucide/svelte/icons/arrow-left-right';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import Check from '@lucide/svelte/icons/check';
	import FileSearch from '@lucide/svelte/icons/file-search';
	import Landmark from '@lucide/svelte/icons/landmark';
	import LockKeyhole from '@lucide/svelte/icons/lock-keyhole';
	import Undo2 from '@lucide/svelte/icons/undo-2';
	import UserRound from '@lucide/svelte/icons/user-round';
	import X from '@lucide/svelte/icons/x';
	import type { Bell } from '#lib/client/bell.svelte.js';
	import type { NotificationItem } from '#lib/contract/notifications.js';
	import { present, when, type BellIcon } from '#lib/notifications.js';

	let {
		bell,
		variant,
		hide = false,
		onfollow
	}: {
		bell: Bell;
		variant: 'popover' | 'page';
		hide?: boolean;
		onfollow?: () => void;
	} = $props();

	const ICONS: Record<BellIcon, typeof Check> = {
		up: ArrowUp,
		down: ArrowDown,
		check: Check,
		x: X,
		swap: ArrowLeftRight,
		undo: Undo2,
		review: FileSearch,
		person: UserRound,
		bank: Landmark,
		lock: LockKeyhole
	};

	const list = $derived(bell.list.kind === 'ready' ? bell.list : null);
	const fresh = $derived(list ? list.items.filter((i) => !i.read) : []);
	const earlier = $derived(list ? list.items.filter((i) => i.read) : []);
	/** NB01: tasks first, then everything else as "Earlier"; S04: New / Earlier. */
	const groups = $derived.by(() => {
		if (!list) return [];
		if (list.actions.length > 0) {
			return [
				{ key: 'actions', label: 'Needs your action', items: list.actions, action: true },
				{ key: 'earlier', label: 'Earlier', items: list.items, action: false }
			];
		}
		if (variant === 'popover') {
			return [{ key: 'all', label: null, items: list.items, action: false }];
		}
		return [
			{ key: 'new', label: 'New', items: fresh, action: false },
			{ key: 'earlier', label: 'Earlier', items: earlier, action: false }
		];
	});

	function follow(item: NotificationItem) {
		void bell.markRead(item);
		onfollow?.();
	}
</script>

{#snippet row(item: NotificationItem, action: boolean)}
	{@const entry = present(item, hide)}
	{@const Icon = ICONS[entry.icon]}
	<li>
		<a
			class="row"
			class:action
			class:unread={!item.read}
			href={entry.href}
			onclick={() => follow(item)}
			data-kind={item.kind}
		>
			<span class="icon tone-{entry.tone}" aria-hidden="true"
				><Icon size={16} strokeWidth={2} /></span
			>
			<span class="text">
				<span class="title">{entry.title}</span>
				{#if entry.line}<span class="line">{entry.line}</span>{/if}
				<span class="time">{when(item.createdAt)}</span>
			</span>
			<span class="dot-slot" aria-hidden="true"
				>{#if !item.read}<span class="dot"></span>{/if}</span
			>
			{#if !item.read}<span class="sr-only">Unread</span>{/if}
		</a>
	</li>
{/snippet}

<div class="list" class:flat={variant === 'popover'} class:page={variant === 'page'}>
	{#each groups.filter((g) => g.items.length > 0) as group, index (group.key)}
		{#if group.items.length > 0}
			{#if group.label}
				<p class="section" class:accent={group.action}>{group.label}</p>
			{/if}
			<ul
				class="group"
				class:card={variant === 'page'}
				class:later={index > 0}
				aria-label={group.label ?? 'Notifications'}
			>
				{#each group.items as item (item.id)}
					{@render row(item, group.action)}
				{/each}
			</ul>
		{/if}
	{/each}
</div>

<style>
	.list {
		display: flex;
		flex-direction: column;
	}

	.list.page {
		gap: 10px;
		padding: 8px 16px;
	}

	.section {
		color: var(--bell-earlier, #9a928c);
		font-family: var(--font-mono);
		font-size: 11px;
		letter-spacing: 0.12em;
		line-height: 14px;
		text-transform: uppercase;
	}

	.section.accent {
		color: var(--color-accent);
	}

	.flat .section {
		padding: 14px 20px 6px;
	}

	.page .section {
		padding-left: 4px;
		font-size: var(--text-12);
		letter-spacing: 0.08em;
		line-height: var(--leading-16);
	}

	.page .section:not(:first-child) {
		padding-top: 8px;
		color: var(--color-muted);
	}

	.group {
		display: flex;
		flex-direction: column;
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.group.card {
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: var(--radius-16);
		background: var(--color-surface);
	}

	:global([data-theme='light']) .group.card {
		border-color: var(--color-border);
	}

	.row {
		display: flex;
		gap: 12px;
		padding: 14px 20px;
		color: inherit;
		text-decoration: none;
	}

	.page .row {
		padding: 14px 16px;
	}

	li + li .row,
	.flat .later li:first-child .row {
		border-top: 1px solid var(--bell-rule, #ffffff0a);
	}

	:global([data-theme='light']) .list {
		--bell-rule: var(--color-border);
	}

	.row.action {
		background: #ff7f4f0d;
	}

	.row:hover {
		background: #ffffff08;
	}

	.row.action:hover {
		background: #ff7f4f17;
	}

	.row:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: -2px;
	}

	.icon {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		border-radius: var(--radius-pill);
	}

	.tone-warning {
		background: color-mix(in oklab, var(--color-warning) 18%, var(--color-surface));
		color: var(--color-warning);
	}

	.tone-success {
		background: color-mix(in oklab, var(--color-success) 15%, var(--color-surface));
		color: var(--color-success);
	}

	.tone-danger {
		background: color-mix(in oklab, var(--color-danger) 15%, var(--color-surface));
		color: var(--color-danger);
	}

	.tone-neutral {
		background: var(--color-raised);
		color: var(--color-text);
	}

	.text {
		display: flex;
		flex: 1 1 0%;
		flex-direction: column;
		gap: 3px;
		min-width: 0;
	}

	.title {
		color: var(--bell-read-title, #d5dadb);
		font-size: var(--text-14);
		line-height: 18px;
	}

	.unread .title {
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
	}

	:global([data-theme='light']) .title {
		--bell-read-title: var(--color-text);
	}

	.line {
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
		overflow-wrap: anywhere;
	}

	/* Paper #7D8588, lifted to #8A9396 for AA contrast on the tinted task rows. */
	.time {
		color: #8a9396;
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	:global([data-theme='light']) .time {
		color: var(--color-muted);
	}

	.dot-slot {
		display: flex;
		align-items: center;
		flex-shrink: 0;
		width: 8px;
	}

	.dot {
		width: 8px;
		height: 8px;
		border-radius: var(--radius-pill);
		background: var(--color-accent);
	}

	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
		white-space: nowrap;
	}
</style>
