<!--
	Quick search (⌘K), Paper "App — Screens v2" K01 (desktop: centered palette
	over a dimmed page, keyboard footer with Root and binoculars) and K02
	(mobile: full-screen sheet, Cancel, Root hint at the bottom). P-06: covers
	what the person can already see in the selected workspace (people, offices,
	references) plus the pages the layout offers. Results never widen authority;
	email and phone arrive masked; amounts follow "Hide amounts".
	Modal (Bits UI Dialog): focus is trapped in the field and returns to the
	trigger. The field is a combobox driving a listbox via aria-activedescendant.
-->
<script lang="ts">
	import { goto } from '$app/navigation';
	import { Dialog } from 'bits-ui';
	import { Effect, Exit } from 'effect';
	import ArrowLeftRight from '@lucide/svelte/icons/arrow-left-right';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import FileText from '@lucide/svelte/icons/file-text';
	import Receipt from '@lucide/svelte/icons/receipt';
	import Undo2 from '@lucide/svelte/icons/undo-2';
	import X from '@lucide/svelte/icons/x';
	import { SearchResults } from '#lib/contract/settings.js';
	import { getJson } from '#lib/client/api.js';
	import {
		buildGroups,
		DEBOUNCE_MS,
		flatten,
		isMacPlatform,
		isNewTabModifier,
		matchPages,
		memberCount,
		moveIndex,
		officeDetail,
		personDetail,
		recordAmount,
		recordDetail,
		searchableQuery,
		searchPath,
		statusTone,
		humanize,
		MAX_QUERY,
		type SearchItem,
		type SearchPage
	} from '#lib/client/search.js';
	import { initials } from '#lib/activity.js';
	import { formatMoney, hiddenMoney } from '#lib/money.js';
	import RootImage from '#lib/ui/RootImage.svelte';

	let {
		open = $bindable(false),
		pages,
		hideAmounts,
		permissions = [],
		onclose
	}: {
		open?: boolean;
		pages: ReadonlyArray<SearchPage>;
		hideAmounts: boolean;
		/** The workspace's permissions: they choose where a record opens. */
		permissions?: readonly string[];
		onclose?: () => void;
	} = $props();

	type Phase = 'idle' | 'loading' | 'ready' | 'error' | 'offline';

	let query = $state('');
	let results = $state<SearchResults | null>(null);
	let phase = $state<Phase>('idle');
	let attempt = $state(0);
	let online = $state(true);
	let wide = $state(true);
	let mac = $state(true);
	let keyed = $state(false);
	let activeId = $state<string | null>(null);
	let input: HTMLInputElement | undefined = $state();

	const q = $derived(searchableQuery(query));
	const pageMatches = $derived(q ? matchPages(pages, q) : []);
	const groups = $derived(buildGroups(q ? results : null, pageMatches, permissions));
	const items = $derived(flatten(groups));
	const activeIndex = $derived.by(() => {
		if (items.length === 0) return -1;
		const i = items.findIndex((item) => item.id === activeId);
		return i < 0 ? 0 : i;
	});
	const active = $derived(activeIndex >= 0 ? items[activeIndex] : undefined);
	const remoteEmpty = $derived(
		phase === 'ready' &&
			!!results &&
			results.people.length + results.offices.length + results.records.length === 0
	);
	const optionId = (item: SearchItem) => `qs-opt-${item.id}`;

	$effect(() => {
		online = navigator.onLine;
		mac = isMacPlatform();
		const media = window.matchMedia('(min-width: 1024px)');
		wide = media.matches;
		const onMedia = () => (wide = media.matches);
		const onOnline = () => (online = true);
		const onOffline = () => (online = false);
		media.addEventListener('change', onMedia);
		window.addEventListener('online', onOnline);
		window.addEventListener('offline', onOffline);
		return () => {
			media.removeEventListener('change', onMedia);
			window.removeEventListener('online', onOnline);
			window.removeEventListener('offline', onOffline);
		};
	});

	// A fresh palette on every open.
	$effect(() => {
		if (!open) return;
		query = '';
		results = null;
		activeId = null;
		keyed = false;
		phase = 'idle';
	});

	// Debounced read; a newer query (or closing) cancels the one in flight.
	$effect(() => {
		const current = q;
		void attempt;
		if (!open || !current) {
			results = null;
			phase = 'idle';
			return;
		}
		if (!online) {
			phase = 'offline';
			return;
		}
		phase = 'loading';
		const controller = new AbortController();
		const timer = setTimeout(() => {
			void Effect.runPromiseExit(
				getJson(searchPath(current), SearchResults, controller.signal)
			).then((exit) => {
				if (controller.signal.aborted) return;
				if (Exit.isSuccess(exit)) {
					results = exit.value;
					phase = 'ready';
				} else {
					results = null;
					phase = 'error';
				}
			});
		}, DEBOUNCE_MS);
		return () => {
			clearTimeout(timer);
			controller.abort();
		};
	});

	$effect(() => {
		if (!active) return;
		document.getElementById(optionId(active))?.scrollIntoView({ block: 'nearest' });
	});

	function close() {
		open = false;
		onclose?.();
	}

	function openItem(item: SearchItem, newTab: boolean) {
		if (newTab) {
			window.open(item.href, '_blank', 'noopener');
			return;
		}
		close();
		void goto(item.href);
	}

	function onKeydown(event: KeyboardEvent) {
		if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
			event.preventDefault();
			keyed = true;
			const next = moveIndex(activeIndex, event.key === 'ArrowDown' ? 1 : -1, items.length);
			activeId = items[next]?.id ?? null;
		} else if (event.key === 'Enter' && !event.isComposing && active) {
			event.preventDefault();
			openItem(active, isNewTabModifier(event, mac));
		}
	}

	function onRowClick(event: MouseEvent) {
		// Modified clicks open a new tab or window natively; keep the palette.
		if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
		close();
	}

	const money = (amount: string, currency: 'NGN' | 'USD', signed: boolean) =>
		hideAmounts ? hiddenMoney(currency) : formatMoney(amount, currency, signed);

	const statusText = $derived.by(() => {
		if (!q) return '';
		if (phase === 'offline') return 'You’re offline.';
		if (phase === 'error') return 'Couldn’t search. Try again.';
		if (phase === 'loading') return 'Searching…';
		if (items.length === 0) return `No matches for “${q}”.`;
		return `${items.length} ${items.length === 1 ? 'result' : 'results'}.`;
	});
</script>

<Dialog.Root
	bind:open
	onOpenChange={(value) => {
		if (!value) onclose?.();
	}}
>
	<Dialog.Portal>
		<Dialog.Overlay class="qs-overlay" />
		<Dialog.Content
			class="qs-dialog"
			aria-label="Quick search"
			onOpenAutoFocus={(event) => {
				event.preventDefault();
				input?.focus();
			}}
		>
			<Dialog.Title class="visually-hidden">Quick search</Dialog.Title>

			<div class="field-row">
				<div class="field">
					<svg class="glass" viewBox="0 0 24 24" aria-hidden="true">
						<circle cx="11" cy="11" r="7" />
						<path d="m20 20-3.5-3.5" />
					</svg>
					<input
						bind:this={input}
						bind:value={query}
						onkeydown={onKeydown}
						type="text"
						role="combobox"
						aria-label="Search people, offices, references and pages"
						aria-expanded={items.length > 0}
						aria-controls="qs-listbox"
						aria-autocomplete="list"
						aria-activedescendant={active ? optionId(active) : undefined}
						aria-describedby="qs-status"
						placeholder="Search by name, UID or reference"
						maxlength={MAX_QUERY}
						autocomplete="off"
						autocapitalize="off"
						spellcheck="false"
						enterkeyhint="go"
					/>
					{#if query && !wide}
						<button
							class="clear"
							type="button"
							aria-label="Clear search"
							onclick={() => {
								query = '';
								input?.focus();
							}}><X size={12} strokeWidth={2.6} aria-hidden="true" /></button
						>
					{/if}
					{#if wide}
						<button class="esc" type="button" aria-label="Close search" onclick={close}
							><span class="kbd">ESC</span></button
						>
					{/if}
				</div>
				{#if !wide}
					<button class="cancel" type="button" onclick={close}>Cancel</button>
				{/if}
			</div>

			<p id="qs-status" class="visually-hidden" role="status" aria-live="polite">{statusText}</p>

			<div class="results">
				{#if !q}
					{#if wide}<p class="note">Search by name, UID or reference</p>{/if}
				{:else}
					{#if phase === 'offline'}
						<p class="note">You’re offline. Pages still open below.</p>
					{:else if phase === 'error'}
						<p class="note">
							Couldn’t search. Try again.
							<button class="retry" type="button" onclick={() => attempt++}>Try again</button>
						</p>
					{:else if phase === 'loading' && !results}
						<p class="note" aria-hidden="true">Searching…</p>
					{:else if remoteEmpty && items.length === 0}
						<p class="note">
							No matches for “{q}”.<span class="note-sub"
								>Try a name, a UID like EW-40117 or a full reference.</span
							>
						</p>
					{/if}

					<div
						id="qs-listbox"
						role="listbox"
						aria-label="Results"
						class:stale={phase === 'loading'}
					>
						{#each groups as group (group.key)}
							<div class="group" role="group" aria-labelledby="qs-group-{group.key}">
								<div class="group-label" id="qs-group-{group.key}" aria-hidden="true">
									{group.label}
								</div>
								{#each group.items as item (item.id)}
									{@const isActive = active?.id === item.id}
									<a
										id={optionId(item)}
										class="row"
										class:page-row={item.kind === 'page'}
										class:record-row={item.kind === 'record'}
										class:active={isActive}
										class:keyed
										role="option"
										aria-selected={isActive}
										tabindex="-1"
										href={item.href}
										onclick={onRowClick}
										onpointermove={() => (activeId = item.id)}
									>
										{#if item.kind === 'person'}
											{@const p = item.person}
											<span class="lead avatar" aria-hidden="true"
												>{initials(p.person?.name, p.person?.uid ?? '··')}</span
											>
											<span class="text">
												<span class="title"
													>{p.person?.name ?? p.person?.uid ?? 'Unnamed'}{p.self
														? ' (you)'
														: ''}</span
												>
												<span class="sub">{personDetail(p, q, !wide)}</span>
											</span>
											{#if wide}
												<span class="trail">
													{#if isActive}<span class="kbd enter" aria-hidden="true">↵</span>{/if}
												</span>
											{/if}
										{:else if item.kind === 'office'}
											{@const o = item.office}
											<span class="lead tile" aria-hidden="true">
												<svg viewBox="0 0 18 18" class="office-icon">
													<rect x="3" y="2.5" width="12" height="13" rx="2" />
													<path d="M6.5 6h1M10.5 6h1M6.5 9h1M10.5 9h1M7.5 15.5v-3h3v3" />
												</svg>
											</span>
											<span class="text">
												<span class="title">{o.name}</span>
												<span class="sub">{officeDetail(o, !wide)}</span>
											</span>
											{#if wide}
												<span class="trail count">{memberCount(o.memberCount)}</span>
											{/if}
										{:else if item.kind === 'record'}
											{@const r = item.record}
											{@const amount = recordAmount(r)}
											<span class="lead avatar" aria-hidden="true">
												{#if r.kind === 'withdrawal'}
													<ArrowUp size={14} strokeWidth={2.2} />
												{:else if r.kind === 'transfer'}
													<ArrowLeftRight size={14} strokeWidth={2.2} />
												{:else if r.kind === 'returned_funds'}
													<Undo2 size={14} strokeWidth={2.2} />
												{:else}
													<Receipt size={14} strokeWidth={2.2} />
												{/if}
											</span>
											<span class="text">
												<span class="title mono">{r.reference}</span>
												<span class="sub">{recordDetail(r, !wide)}</span>
											</span>
											{#if amount || r.status}
												<span class="trail figures">
													{#if amount && r.amount}
														<span class="amount"
															>{money(amount.amount, r.amount.currency, amount.signed)}</span
														>
													{/if}
													{#if r.status}
														<span class="status" data-tone={statusTone(r.status)}
															>{humanize(r.status)}</span
														>
													{/if}
												</span>
											{:else if wide}
												<span class="trail"></span>
											{/if}
										{:else}
											{@const Icon = item.page.icon ?? FileText}
											<span class="lead plain" aria-hidden="true"
												><Icon size={16} strokeWidth={1.5} /></span
											>
											<span class="text">
												<span class="title page-title">{item.page.label}</span>
											</span>
											{#if wide}<span class="trail"></span>{/if}
										{/if}
									</a>
								{/each}
							</div>
						{/each}
					</div>
				{/if}
			</div>

			{#if wide}
				<div class="footer">
					<span class="hint"><span class="kbd" aria-hidden="true">↑↓</span>Move</span>
					<span class="hint"><span class="kbd" aria-hidden="true">↵</span>Open</span>
					<span class="hint"
						><span class="kbd" aria-hidden="true">{mac ? '⌘↵' : 'Ctrl ↵'}</span>Open in new tab</span
					>
					<span class="spacer"></span>
					<RootImage pose="quick-search" class="root-crop" sizes="60px" eager />
				</div>
			{:else}
				<div class="mobile-hint">
					<RootImage pose="quick-search" class="root-full" sizes="84px" eager />
					<p>Search by name, UID or reference</p>
				</div>
			{/if}
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	/* Paper K01/K02 neutrals; light falls back to the theme tokens. */
	:global(.qs-dialog) {
		--qs-line: color-mix(in oklab, var(--color-text) 8%, transparent);
		--qs-edge: color-mix(in oklab, var(--color-text) 10%, transparent);
		--qs-active-edge: color-mix(in oklab, var(--color-text) 12%, transparent);
		--qs-faint: #7d8588;
		--qs-strong: #d5dadb;
		--qs-chip-strong: var(--color-border);
		--qs-field: #141718;
		--qs-footer: color-mix(in oklab, var(--color-surface) 50%, var(--color-canvas));
		--qs-shadow: #ffffff0f 0px 1px 0px inset, #000000cc 0px 40px 80px -20px;
	}

	:global([data-theme='light'] .qs-dialog) {
		--qs-faint: var(--color-muted);
		--qs-strong: var(--color-text);
		--qs-chip-strong: var(--color-border);
		--qs-field: var(--color-surface);
		--qs-shadow: #00000014 0px 1px 0px inset, #2126283d 0px 40px 80px -20px;
	}

	@media (prefers-color-scheme: light) {
		:global([data-theme='system'] .qs-dialog) {
			--qs-faint: var(--color-muted);
			--qs-strong: var(--color-text);
			--qs-chip-strong: var(--color-border);
			--qs-field: var(--color-surface);
			--qs-shadow: #00000014 0px 1px 0px inset, #2126283d 0px 40px 80px -20px;
		}
	}

	:global(.qs-overlay) {
		position: fixed;
		inset: 0;
		z-index: 60;
		background: #08090a9e;
	}

	/* K02: full-screen sheet. */
	:global(.qs-dialog) {
		position: fixed;
		inset: 0;
		z-index: 61;
		display: flex;
		flex-direction: column;
		background: var(--color-canvas);
		color: var(--color-text);
		font-size: var(--text-12);
		line-height: var(--leading-16);
		overflow-wrap: anywhere;
		padding-top: env(safe-area-inset-top);
		outline: none;
	}

	.field-row {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 12px 20px 12px;
		flex-shrink: 0;
	}

	.field {
		display: flex;
		align-items: center;
		flex: 1 1 0;
		min-width: 0;
		gap: 10px;
		height: 48px;
		padding: 0 6px 0 14px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: var(--qs-field);
	}

	.field:focus-within {
		border-color: var(--color-accent-text);
		box-shadow: 0 0 0 3px color-mix(in oklab, var(--color-accent-text) 20%, transparent);
	}

	.glass {
		width: 18px;
		height: 18px;
		flex-shrink: 0;
		fill: none;
		stroke: var(--color-accent-text);
		stroke-width: 2;
		stroke-linecap: round;
	}

	input {
		flex: 1 1 0;
		min-width: 0;
		height: 100%;
		border: 0;
		padding: 0;
		background: transparent;
		color: var(--color-text);
		caret-color: var(--color-accent-text);
		font-family: var(--font-sans);
		font-size: var(--text-16);
		line-height: 22px;
		outline: none;
	}

	input::placeholder {
		color: var(--qs-faint);
	}

	.clear {
		position: relative;
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--color-muted);
		cursor: pointer;
	}

	/* 44px hit area around the 36px chip. */
	.clear::before {
		content: '';
		position: absolute;
		inset: -4px;
	}

	.cancel {
		flex-shrink: 0;
		min-height: var(--hit-min);
		padding: 0 0 0 4px;
		border: 0;
		background: none;
		color: var(--color-text);
		font-family: var(--font-sans);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
		cursor: pointer;
	}

	.results {
		flex: 1 1 auto;
		min-height: 0;
		overflow-y: auto;
		overscroll-behavior: contain;
		padding: 0 12px;
	}

	.note {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 4px;
		margin: 0;
		padding: 12px 8px;
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.note-sub {
		color: var(--qs-faint);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.retry {
		min-height: var(--hit-min);
		padding: 0;
		border: 0;
		background: none;
		color: var(--color-accent-text);
		font: inherit;
		font-weight: var(--font-weight-medium);
		text-decoration: underline;
		text-underline-offset: 3px;
		cursor: pointer;
	}

	[role='listbox'].stale {
		opacity: 0.7;
	}

	.group {
		display: flex;
		flex-direction: column;
	}

	.group-label {
		padding: 16px 8px 6px;
		color: var(--qs-faint);
		font-family: var(--font-mono);
		font-size: 11px;
		line-height: 14px;
		letter-spacing: 0.06em;
		text-transform: uppercase;
	}

	.group:first-child .group-label {
		padding-top: 12px;
	}

	.row {
		display: flex;
		align-items: center;
		flex-shrink: 0;
		gap: 12px;
		min-height: 56px;
		padding: 0 8px;
		border: 1px solid transparent;
		border-radius: var(--radius-12);
		color: inherit;
		text-decoration: none;
		cursor: pointer;
	}

	.row.record-row {
		min-height: 60px;
	}

	.row.page-row {
		min-height: 48px;
	}

	/* K02 draws no row highlight; show it once the keyboard moves. */
	.row.active.keyed {
		border-color: var(--qs-active-edge);
		background: var(--color-raised);
	}

	.lead {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		color: var(--qs-strong);
	}

	.avatar {
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		font-family: var(--font-sans);
		font-size: var(--text-12);
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-16);
	}

	.row.active .avatar {
		background: var(--color-accent-subtle);
		color: var(--color-accent-text);
	}

	.tile {
		border-radius: 10px;
		background: var(--color-raised);
	}

	.plain {
		color: var(--color-muted);
	}

	.office-icon {
		width: 16px;
		height: 16px;
		fill: none;
		stroke: var(--color-muted);
		stroke-width: 1.5;
		stroke-linecap: round;
	}

	.text {
		display: flex;
		flex-direction: column;
		flex: 1 1 0;
		min-width: 0;
	}

	.title {
		color: var(--color-text);
		font-family: var(--font-sans);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	.title.mono {
		font-family: var(--font-mono);
		font-size: 13px;
		line-height: 18px;
	}

	.title.page-title {
		font-weight: var(--font-weight-regular);
	}

	.sub {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.trail {
		display: flex;
		justify-content: flex-end;
		flex-shrink: 0;
	}

	.figures {
		flex-direction: column;
		align-items: flex-end;
		text-align: right;
	}

	.amount {
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		white-space: nowrap;
	}

	.status {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.status[data-tone='success'] {
		color: var(--color-success);
	}

	.status[data-tone='warning'] {
		color: var(--color-warning);
	}

	.status[data-tone='danger'] {
		color: var(--color-danger);
	}

	.count {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
		text-align: right;
	}

	.kbd {
		display: inline-block;
		padding: 3px 6px;
		border-radius: 6px;
		background: var(--color-raised);
		color: var(--qs-strong);
		font-family: var(--font-mono);
		font-size: 11px;
		line-height: 14px;
		white-space: nowrap;
	}

	.kbd.enter {
		padding: 3px 7px;
		background: var(--qs-chip-strong);
	}

	.mobile-hint {
		display: flex;
		align-items: flex-end;
		gap: 12px;
		flex-shrink: 0;
		padding: 12px 20px calc(28px + env(safe-area-inset-bottom));
	}

	.mobile-hint p {
		flex: 1 1 0;
		margin: 0;
		padding-bottom: 14px;
		color: var(--qs-strong);
		font-family: var(--font-sans);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	.mobile-hint :global(.root-full) {
		flex-shrink: 0;
		width: 84px;
		height: 112px;
	}

	@media (max-height: 600px) {
		.mobile-hint {
			display: none;
		}
	}

	/* K01: centered palette over the dimmed page. */
	@media (min-width: 1024px) {
		:global(.qs-dialog) {
			inset: 96px auto auto 50%;
			width: min(640px, calc(100vw - 32px));
			max-height: calc(100dvh - 192px);
			transform: translateX(-50%);
			padding-top: 0;
			overflow: clip;
			border: 1px solid var(--qs-edge);
			border-radius: 22px;
			background: var(--color-surface);
			box-shadow: var(--qs-shadow);
		}

		.field-row {
			padding: 0;
		}

		.field {
			gap: 12px;
			height: 64px;
			padding: 0 6px 0 20px;
			border: 0;
			border-bottom: 1px solid var(--qs-line);
			border-radius: 0;
			background: transparent;
		}

		.field:focus-within {
			box-shadow: none;
		}

		.glass {
			width: 20px;
			height: 20px;
		}

		input {
			font-size: 18px;
			line-height: var(--leading-24);
		}

		/* The 22px ESC chip inside a 44px target. */
		.esc {
			display: flex;
			align-items: center;
			justify-content: center;
			flex-shrink: 0;
			min-width: var(--hit-min);
			height: var(--hit-min);
			padding: 0;
			border: 0;
			border-radius: var(--radius-8);
			background: none;
			cursor: pointer;
		}

		.esc .kbd {
			padding: 4px 8px;
			color: var(--color-muted);
		}

		.results {
			padding: 8px 8px 12px;
		}

		.note {
			padding: 10px 12px;
		}

		.group-label {
			padding: 14px 12px 6px;
		}

		.group:first-child .group-label {
			padding-top: 10px;
		}

		.row {
			min-height: 52px;
			padding: 0 12px;
		}

		.row.record-row {
			min-height: 52px;
		}

		.row.page-row {
			min-height: var(--hit-min);
		}

		.row.active {
			border-color: var(--qs-active-edge);
			background: var(--color-raised);
		}

		.lead {
			width: 32px;
			height: 32px;
		}

		.title {
			font-family: system-ui, sans-serif;
			font-size: var(--text-14);
			line-height: 18px;
		}

		.title.page-title {
			color: var(--color-muted);
		}

		.sub,
		.amount,
		.status,
		.count,
		.avatar {
			font-family: system-ui, sans-serif;
		}

		.trail {
			width: 120px;
		}

		.footer {
			display: flex;
			align-items: center;
			flex-shrink: 0;
			gap: 20px;
			height: 48px;
			padding: 0 20px;
			border-top: 1px solid var(--qs-line);
			background: var(--qs-footer);
		}

		.hint {
			display: flex;
			align-items: center;
			gap: 6px;
			color: var(--color-muted);
			font-family: var(--font-sans);
			font-size: var(--text-12);
			line-height: var(--leading-16);
			white-space: nowrap;
		}

		.spacer {
			flex-grow: 1;
		}

		.footer :global(.root-crop) {
			align-self: flex-end;
			flex-shrink: 0;
			width: 60px;
			height: 48px;
			object-fit: cover;
			object-position: 50% 8%;
		}
	}

	@media (prefers-reduced-motion: no-preference) {
		:global(.qs-overlay[data-state='open']) {
			animation: qs-fade 140ms ease-out;
		}

		@media (min-width: 1024px) {
			:global(.qs-dialog[data-state='open']) {
				animation: qs-rise 160ms ease-out;
			}
		}
	}

	@keyframes -global-qs-fade {
		from {
			opacity: 0;
		}
	}

	@keyframes -global-qs-rise {
		from {
			opacity: 0;
			transform: translate(-50%, -6px);
		}
	}
</style>
