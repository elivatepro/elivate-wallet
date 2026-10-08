<!--
	Member field of Record income (Paper v4 J01 "Member"): the closed field is
	drawn; the sheet that opens is not drawn yet (Blueprint 09). Lists only
	members the backend says the leader may record income for. Search runs on
	the server across the whole network (owner decision 2026-10-08); "Load more"
	pages the backend cursor of the list being shown.
-->
<script lang="ts">
	import { Dialog } from 'bits-ui';
	import Check from '@lucide/svelte/icons/check';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import type { IncomeTarget, IncomeTargets } from '#lib/contract/income.js';
	import { initials } from '#lib/income.js';

	let {
		targets,
		selected = $bindable(null),
		hasMore = false,
		loadingMore = false,
		disabled = false,
		error = null,
		onLoadMore,
		onChange,
		search
	}: {
		targets: ReadonlyArray<IncomeTarget>;
		selected?: IncomeTarget | null;
		hasMore?: boolean;
		loadingMore?: boolean;
		disabled?: boolean;
		error?: string | null;
		onLoadMore: () => void;
		onChange?: (target: IncomeTarget) => void;
		/** One page of server-side search results; null when the read failed. */
		search: (query: string, cursor: string | null) => Promise<IncomeTargets | null>;
	} = $props();

	let open = $state(false);
	let query = $state('');
	let results = $state<IncomeTarget[]>([]);
	let resultsCursor = $state<string | null>(null);
	let searching = $state(false);
	let searchFailed = $state(false);
	let timer: ReturnType<typeof setTimeout> | undefined;
	/** Drops answers to older queries (typing fast). */
	let generation = 0;

	export function openPicker() {
		open = true;
	}

	function onQuery() {
		clearTimeout(timer);
		const q = query.trim();
		generation += 1;
		if (!q) {
			searching = false;
			searchFailed = false;
			return;
		}
		searching = true;
		const mine = generation;
		timer = setTimeout(async () => {
			const page = await search(q.slice(0, 100), null);
			if (mine !== generation) return;
			searching = false;
			searchFailed = !page;
			results = page ? [...page.items] : [];
			resultsCursor = page?.nextCursor ?? null;
		}, 250);
	}

	async function moreResults() {
		const q = query.trim();
		if (!q || !resultsCursor) return;
		const mine = generation;
		searching = true;
		const page = await search(q.slice(0, 100), resultsCursor);
		if (mine !== generation) return;
		searching = false;
		if (!page) return void (searchFailed = true);
		const seen = new Set(results.map((t) => t.membershipId));
		results = [...results, ...page.items.filter((t) => !seen.has(t.membershipId))];
		resultsCursor = page.nextCursor;
	}

	const label = (t: IncomeTarget) => t.person?.name ?? t.person?.uid ?? 'Member';
	const detail = (t: IncomeTarget) =>
		t.person ? `UID ${t.person.uid} · ${t.officeName}` : t.officeName;

	const searchingNow = $derived(query.trim().length > 0);
	const shown = $derived(searchingNow ? results : targets);

	function choose(target: IncomeTarget) {
		selected = target;
		onChange?.(target);
		open = false;
	}
</script>

<div class="field">
	<span class="label" id="member-label">Member</span>
	<Dialog.Root bind:open>
		<Dialog.Trigger
			class="member-trigger"
			{disabled}
			aria-labelledby="member-label member-value"
			aria-invalid={error ? 'true' : undefined}
			aria-describedby={error ? 'member-error' : undefined}
		>
			{#if selected}
				<span class="avatar" aria-hidden="true"
					>{initials(selected.person?.name, selected.person?.uid ?? '')}</span
				>
				<span class="text" id="member-value">
					<span class="name">{label(selected)}</span>
					<span class="sub">{detail(selected)}</span>
				</span>
			{:else}
				<span class="text" id="member-value"><span class="placeholder">Choose a member</span></span>
			{/if}
			<ChevronDown size={16} strokeWidth={2} aria-hidden="true" class="chev" />
		</Dialog.Trigger>
		<Dialog.Portal>
			<Dialog.Overlay class="confirm-overlay" />
			<Dialog.Content class="confirm-dialog picker-dialog">
				<div class="picker-body">
					<Dialog.Title class="picker-title">Choose the member</Dialog.Title>
					<input
						class="search"
						type="search"
						placeholder="Search name, UID or office"
						aria-label="Search members"
						maxlength="100"
						bind:value={query}
						oninput={onQuery}
					/>
					{#if searchingNow && searching}<p class="none" role="status">Searching…</p>{/if}
					<ul class="list" aria-label="Members">
						{#each shown as target (target.membershipId)}
							<li>
								<button
									type="button"
									class="option"
									aria-pressed={selected?.membershipId === target.membershipId}
									onclick={() => choose(target)}
								>
									<span class="avatar" aria-hidden="true"
										>{initials(target.person?.name, target.person?.uid ?? '')}</span
									>
									<span class="text">
										<span class="name">{label(target)}</span>
										<span class="sub">{detail(target)}</span>
									</span>
									<span class="tick" aria-hidden="true">
										{#if selected?.membershipId === target.membershipId}<Check
												size={16}
												strokeWidth={2}
											/>{/if}
									</span>
								</button>
							</li>
						{:else}
							{#if searchingNow && !searching}
								<li class="none">
									{searchFailed
										? 'We couldn’t search right now. Try again.'
										: `No member matches “${query.trim()}”.`}
								</li>
							{/if}
						{/each}
					</ul>
					{#if searchingNow ? !!resultsCursor : hasMore}
						<button
							type="button"
							class="more"
							onclick={() => (searchingNow ? moreResults() : onLoadMore())}
							disabled={searchingNow ? searching : loadingMore}
							aria-busy={searchingNow ? searching : loadingMore}>Load more members</button
						>
					{/if}
				</div>
				<div class="confirm-actions">
					<Dialog.Close class="confirm-cancel" type="button">Close</Dialog.Close>
				</div>
			</Dialog.Content>
		</Dialog.Portal>
	</Dialog.Root>
	{#if error}<p class="error" id="member-error">{error}</p>{/if}
</div>

<style>
	.field {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.label {
		color: var(--shell-strong, var(--color-text));
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: 16px;
	}

	:global(.member-trigger) {
		display: flex;
		align-items: center;
		gap: 12px;
		width: 100%;
		height: 56px;
		padding: 0 16px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		text-align: left;
		cursor: pointer;
	}

	:global(.member-trigger[aria-invalid='true']) {
		border-color: var(--color-danger);
	}

	:global(.member-trigger:disabled) {
		cursor: default;
		opacity: var(--opacity-disabled);
	}

	:global(.member-trigger .chev) {
		flex-shrink: 0;
		color: var(--color-muted);
	}

	.avatar {
		display: flex;
		flex-shrink: 0;
		align-items: center;
		justify-content: center;
		width: 32px;
		height: 32px;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--shell-strong, var(--color-text));
		font-size: 12px;
		font-weight: var(--font-weight-semibold);
		line-height: 16px;
	}

	.text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 1px;
		min-width: 0;
	}

	.name {
		overflow: hidden;
		color: var(--color-text);
		font-size: 14px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.sub {
		overflow: hidden;
		color: var(--color-muted);
		font-size: 12px;
		line-height: 16px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.placeholder {
		color: var(--shell-faint, var(--color-muted));
		font-size: 15px;
		line-height: 18px;
	}

	.error {
		color: var(--color-danger);
		font-size: var(--text-14);
	}

	.picker-body {
		display: flex;
		flex-direction: column;
		gap: 12px;
		padding: 28px 28px 12px;
	}

	:global(.picker-title) {
		font-size: var(--text-24);
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.02em;
		line-height: var(--leading-32);
	}

	.search {
		height: 48px;
		padding: 0 16px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-12);
		background: color-mix(in oklab, var(--color-canvas) 60%, transparent);
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
	}

	.search:focus {
		outline: none;
		border-color: var(--color-accent);
	}

	.list {
		display: flex;
		flex-direction: column;
		gap: 2px;
		max-height: min(50dvh, 420px);
		margin: 0 -8px;
		overflow-y: auto;
		list-style: none;
	}

	.option {
		display: flex;
		align-items: center;
		gap: 12px;
		width: 100%;
		min-height: 56px;
		padding: 8px;
		border: 0;
		border-radius: var(--radius-12);
		background: transparent;
		color: inherit;
		font: inherit;
		text-align: left;
		cursor: pointer;
	}

	.option:hover,
	.option[aria-pressed='true'] {
		background: var(--color-raised);
	}

	.tick {
		display: flex;
		flex-shrink: 0;
		justify-content: center;
		width: 20px;
		color: var(--color-accent);
	}

	.none {
		padding: 16px 8px;
		color: var(--color-muted);
		font-size: var(--text-14);
	}

	.more {
		align-self: flex-start;
		min-height: var(--hit-min);
		padding: 0 4px;
		border: 0;
		background: none;
		color: var(--color-accent-text);
		font: inherit;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		cursor: pointer;
	}
</style>
