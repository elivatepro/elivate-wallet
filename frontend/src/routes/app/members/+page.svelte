<!--
	Members, Paper "App — Screens v1" C11 (desktop) / C12 (mobile): the
	workspace's memberships (its office subtree; the President Team: the whole
	network), searchable by name or UID on the server, filtered by status ("Current" = active and suspended).
	Invitations live on their own page (I01); "Last activity" is not available
	yet, so the row shows the office and role instead.
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext, onMount, untrack } from 'svelte';
	import { page } from '$app/state';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Plus from '@lucide/svelte/icons/plus';
	import Search from '@lucide/svelte/icons/search';
	import { UUID_PATTERN } from '#lib/contract/common.js';
	import { AppOrgRoutes, MemberRows, type MemberRow } from '#lib/contract/org-admin.js';
	import { loadView } from '#lib/client/org.svelte.js';
	import { CachedRead } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { initials, personName, STATUS_LABELS } from '#lib/org.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import OrgHero from '#lib/ui/org/OrgHero.svelte';

	const shell = getContext<Shell>('shell');
	const canInvite = $derived(
		shell.state.kind === 'ready' &&
			(shell.state.view.capabilities?.permissions ?? []).includes('invite_members')
	);
	const officeId = $derived.by(() => {
		const value = page.url.searchParams.get('officeId');
		return value && UUID_PATTERN.test(value) ? value : null;
	});

	let items = $state<MemberRow[]>([]);
	let nextCursor = $state<string | null>(null);
	let loaded = $state(false);
	let loadError = $state<string | null>(null);
	let loadingMore = $state(false);
	let query = $state('');
	let status = $state<'all' | 'active' | 'suspended' | 'ended'>('all');
	let seq = 0;
	let timer: ReturnType<typeof setTimeout> | undefined;

	/** Blueprint 20 B6: the unfiltered first page opens from cache, then refreshes. */
	const cached = new CachedRead<typeof MemberRows.Type>('members');
	let cachedAt = $state<number | null>(null);
	const unfiltered = () => !query.trim() && status === 'all' && !officeId;

	async function load(more = false) {
		const mine = ++seq;
		const first = !more && unfiltered();
		// Built and read once per call; not reactive state.
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const params = new URLSearchParams();
		if (query.trim()) params.set('q', query.trim());
		if (status !== 'all') params.set('status', status);
		if (officeId) params.set('officeId', officeId);
		if (more && nextCursor) params.set('cursor', nextCursor);
		loadingMore = more;
		const ticket = cached.begin();
		const result = await loadView(
			`${AppOrgRoutes.members}${params.size ? `?${params}` : ''}`,
			MemberRows
		);
		if (mine !== seq) return;
		loadingMore = false;
		// Another tab switched workspace while this ran: the rows are not ours.
		if (!cached.current(ticket)) return load();
		if (result.ok) {
			items = more ? [...items, ...result.value.items] : [...result.value.items];
			nextCursor = result.value.nextCursor;
			loaded = true;
			loadError = null;
			if (first) cached.fresh(result.value, shell.scope, ticket);
			cachedAt = null;
		} else loadError = result.text;
	}

	onMount(() => {
		if (unfiltered() && cached.show() && cached.data) {
			items = [...cached.data.items];
			nextCursor = cached.data.nextCursor;
			loaded = true;
			cachedAt = cached.savedAt;
		}
		return cached.watch(() => void load());
	});
	// Starts with /api/session, not after it, and again when back online.
	$effect(() => {
		if (shell.readable) untrack(() => void load());
	});
	$effect(() => {
		if (!shell.scope) return;
		cached.confirm(shell.scope);
		if (cachedAt !== null && !cached.data) {
			items = [];
			nextCursor = null;
			loaded = false;
			cachedAt = null;
		}
	});

	function onSearch() {
		clearTimeout(timer);
		timer = setTimeout(() => void load(), 300);
	}

	/** Slice 28 (owner decision 2026-10-11): the list never shows the person themselves. */
	const myUid = $derived(shell.state.kind === 'ready' ? shell.state.view.state.uid : null);
	const others = $derived(items.filter((m) => !myUid || m.person?.uid !== myUid));
	const officeName = $derived(officeId ? (items[0]?.officeName ?? null) : null);
	const joined = (iso: string) =>
		new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }).format(
			new Date(iso)
		);
	const FILTERS = [
		{ value: 'all', label: 'Current' },
		{ value: 'active', label: 'Active' },
		{ value: 'suspended', label: 'Suspended' },
		{ value: 'ended', label: 'Ended' }
	] as const;
</script>

<svelte:head><title>Members · Elivate Wallet</title></svelte:head>

<div class="o-page">
	<OrgHero
		id="members-heading"
		pose={null}
		title={loaded && !nextCursor
			? `${others.length} ${others.length === 1 ? 'member' : 'members'}`
			: 'Members'}
		line={officeName ? `${officeName} and below` : null}
	>
		{#snippet actions()}
			{#if canInvite}
				<a class="hero-cta" href="/app/invitations?invite"
					><Plus size={18} strokeWidth={2.2} aria-hidden="true" />Invite a member</a
				>
			{/if}
		{/snippet}
	</OrgHero>

	<div class="o-toolbar">
		<label class="o-search">
			<Search size={16} strokeWidth={2} aria-hidden="true" />
			<span class="visually-hidden">Search name or UID</span>
			<input type="search" placeholder="Search name or UID" bind:value={query} oninput={onSearch} />
		</label>
		<fieldset class="o-tabs">
			<legend class="visually-hidden">Status</legend>
			{#each FILTERS as filter (filter.value)}
				<label class="o-tab">
					<input
						type="radio"
						name="member-status"
						value={filter.value}
						bind:group={status}
						onchange={() => load()}
					/>
					<span>{filter.label}</span>
				</label>
			{/each}
		</fieldset>
	</div>

	<CacheNote savedAt={cachedAt} online={shell.online} failed={loadError !== null} />
	{#if !loaded && (!loadError || shell.state.kind === 'loading')}
		<div class="o-skeleton" aria-hidden="true"></div>
		<p class="visually-hidden" role="status">Loading members</p>
	{:else if loadError && cachedAt === null}
		<div class="o-error" role="alert">
			<p>{loadError}</p>
			<button type="button" class="o-ghost" onclick={() => load()}>Try again</button>
		</div>
	{:else if others.length === 0}
		<p class="o-card o-empty">{query.trim() ? 'No members match.' : 'No members here yet.'}</p>
	{:else}
		<section class="o-card" aria-label="Members">
			<div class="o-cols" aria-hidden="true">
				<span class="o-grow">Member</span>
				<span class="c-status">Status</span>
				<span class="c-joined">Joined</span>
				<span class="c-office">Office · role</span>
				<span class="c-chev"></span>
			</div>
			<ul class="o-rows">
				{#each others as member (member.membershipId)}
					<li>
						<a class="o-row" href={`/app/members/${member.membershipId}`}>
							<span class="o-avatar" class:coral={member.status === 'active'} aria-hidden="true"
								>{initials(member.person)}</span
							>
							<span class="o-stack o-grow">
								<span class="o-title">{personName(member.person)}</span>
								<span class="o-sub o-wide"
									>{member.emailMasked ? `${member.emailMasked} · ` : ''}{member.person?.uid ??
										''}</span
								>
								<span class="o-sub o-narrow"
									>{STATUS_LABELS[member.status]} · {member.officeName ?? 'President Team'}</span
								>
							</span>
							<span class="c-status o-wide"
								><span class="o-pill" data-status={member.status}
									>{STATUS_LABELS[member.status]}</span
								></span
							>
							<span class="c-joined o-wide">{joined(member.startedAt)}</span>
							<span class="c-office o-wide"
								>{member.officeName ?? 'President Team'} · {ROLE_LABELS[member.role]}</span
							>
							<span class="c-chev" aria-hidden="true"
								><ChevronRight size={16} strokeWidth={1.5} /></span
							>
						</a>
					</li>
				{/each}
			</ul>
		</section>
		{#if nextCursor}
			<button
				type="button"
				class="o-ghost more"
				disabled={loadingMore}
				aria-busy={loadingMore}
				onclick={() => load(true)}>Show more</button
			>
		{/if}
	{/if}
</div>

<style>
	.more {
		align-self: center;
	}

	.c-chev {
		display: flex;
		color: var(--o-faint);
	}

	@media (min-width: 1024px) {
		.o-row {
			height: 64px;
		}

		.c-status {
			flex-shrink: 0;
			width: 140px;
		}

		.c-joined {
			flex-shrink: 0;
			width: 140px;
			color: var(--o-strong);
			font-size: 13px;
		}

		.c-office {
			flex-shrink: 0;
			width: 220px;
			overflow: hidden;
			color: var(--o-strong);
			font-size: 13px;
			text-overflow: ellipsis;
			white-space: nowrap;
		}

		.c-chev {
			justify-content: center;
			width: 24px;
		}
	}
</style>
