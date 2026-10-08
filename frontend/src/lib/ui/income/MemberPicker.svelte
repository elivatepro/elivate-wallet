<!--
	Member field of Record income (Paper T02/T05 "Member"): the closed field is
	drawn; the sheet that opens is a stub until Paper draws it (Blueprint 09).
	Lists only members the backend says the leader may record income for;
	search filters the loaded pages, "Load more" pages the backend cursor.
-->
<script lang="ts">
	import { Dialog } from 'bits-ui';
	import Check from '@lucide/svelte/icons/check';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import type { IncomeTarget } from '#lib/contract/income.js';
	import { initials } from '#lib/income.js';

	let {
		targets,
		selected = $bindable(null),
		hasMore = false,
		loadingMore = false,
		disabled = false,
		error = null,
		onLoadMore,
		onChange
	}: {
		targets: ReadonlyArray<IncomeTarget>;
		selected?: IncomeTarget | null;
		hasMore?: boolean;
		loadingMore?: boolean;
		disabled?: boolean;
		error?: string | null;
		onLoadMore: () => void;
		onChange?: (target: IncomeTarget) => void;
	} = $props();

	let open = $state(false);
	let query = $state('');

	const label = (t: IncomeTarget) => t.person?.name ?? t.person?.uid ?? 'Member';
	const detail = (t: IncomeTarget) =>
		t.person ? `UID ${t.person.uid} · ${t.officeName}` : t.officeName;

	const shown = $derived.by(() => {
		const q = query.trim().toLowerCase();
		if (!q) return targets;
		return targets.filter((t) =>
			[t.person?.name ?? '', t.person?.uid ?? '', t.officeName].some((v) =>
				v.toLowerCase().includes(q)
			)
		);
	});

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
						bind:value={query}
					/>
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
							<li class="none">No member matches “{query.trim()}”.</li>
						{/each}
					</ul>
					{#if hasMore}
						<button
							type="button"
							class="more"
							onclick={onLoadMore}
							disabled={loadingMore}
							aria-busy={loadingMore}>Load more members</button
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
