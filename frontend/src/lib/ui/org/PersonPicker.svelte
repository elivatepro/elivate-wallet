<!--
	Person picker (Blueprint 27, Paper "Person picker v6" PP01/PP02). One field
	for a name, a UID or an email address. Names match the network's people
	(GET /api/org/people); a UID or a full email matches any account exactly.
	With `allowInvite`, a full email no account uses becomes an invitation
	(leader forms only); otherwise the person must have an account first.
-->
<script lang="ts">
	import { Effect, Exit } from 'effect';
	import Mail from '@lucide/svelte/icons/mail';
	import Search from '@lucide/svelte/icons/search';
	import X from '@lucide/svelte/icons/x';
	import { AppOrgRoutes, FoundPeople, type FoundPerson } from '#lib/contract/org-admin.js';
	import { INVITE_EMAIL_PATTERN } from '#lib/contract/invitations.js';
	import { getJson } from '#lib/client/api.js';
	import { initials } from '#lib/activity.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import { type Picked, pickerQuery } from '#lib/person-picker.js';

	let {
		id,
		value = $bindable(null),
		allowInvite = false,
		networkName = null
	}: {
		id: string;
		value?: Picked | null;
		allowInvite?: boolean;
		networkName?: string | null;
	} = $props();

	let query = $state('');
	let items = $state<ReadonlyArray<FoundPerson>>([]);
	let noAccount = $state(false);
	let searching = $state(false);
	let failed = $state(false);
	let active = $state(0);

	const kind = $derived(pickerQuery(query));
	const listId = $derived(`${id}-results`);
	const inviteRow = $derived(allowInvite && noAccount && kind === 'email');
	const rows = $derived(items.length + (inviteRow ? 1 : 0));

	// Searches 250 ms after typing stops; a newer query cancels the older read.
	$effect(() => {
		const q = query.trim();
		items = [];
		noAccount = false;
		failed = false;
		active = 0;
		if (kind === 'short') {
			searching = false;
			return;
		}
		const controller = new AbortController();
		searching = true;
		const timer = setTimeout(async () => {
			const exit = await Effect.runPromiseExit(
				getJson(`${AppOrgRoutes.people}?q=${encodeURIComponent(q)}`, FoundPeople, controller.signal)
			);
			if (controller.signal.aborted) return;
			searching = false;
			if (Exit.isSuccess(exit)) {
				items = exit.value.items;
				noAccount = exit.value.noAccount;
			} else failed = true;
		}, 250);
		return () => {
			clearTimeout(timer);
			controller.abort();
		};
	});

	function choose(index: number) {
		const person = items[index];
		if (person) value = { kind: 'person', uid: person.uid, name: person.name };
		else if (inviteRow) value = { kind: 'invite', email: query.trim().toLowerCase() };
		else return;
		query = '';
	}

	function keydown(event: KeyboardEvent) {
		if (!rows) return;
		if (event.key === 'ArrowDown') active = (active + 1) % rows;
		else if (event.key === 'ArrowUp') active = (active - 1 + rows) % rows;
		else if (event.key === 'Enter') choose(active);
		else return;
		event.preventDefault();
	}

	const subline = (person: FoundPerson) =>
		[
			person.uid,
			person.role ? ROLE_LABELS[person.role] : null,
			person.officeName,
			person.inNetwork ? null : 'Not in this network yet'
		]
			.filter(Boolean)
			.join(' · ');
</script>

{#if value}
	<div class="chosen" data-testid="picked">
		{#if value.kind === 'person'}
			<span class="avatar">{initials(value.name, value.uid)}</span>
			<span class="text">
				<span class="name">{value.name ?? value.uid}</span>
				<span class="sub">{value.uid}</span>
			</span>
		{:else}
			<span class="avatar mail"><Mail size={16} strokeWidth={1.6} aria-hidden="true" /></span>
			<span class="text">
				<span class="name">{value.email}</span>
				<span class="sub">No account yet · we’ll invite them</span>
			</span>
		{/if}
		<button
			type="button"
			class="clear"
			aria-label="Choose someone else"
			onclick={() => (value = null)}
		>
			<X size={16} strokeWidth={1.8} aria-hidden="true" />
		</button>
	</div>
{:else}
	<div class="search">
		<Search size={16} strokeWidth={1.6} aria-hidden="true" />
		<input
			{id}
			class="input"
			type="search"
			role="combobox"
			aria-expanded={rows > 0}
			aria-controls={listId}
			aria-autocomplete="list"
			aria-activedescendant={rows ? `${id}-row-${active}` : undefined}
			placeholder="Name, email or UID"
			autocomplete="off"
			autocapitalize="off"
			spellcheck="false"
			maxlength="254"
			bind:value={query}
			onkeydown={keydown}
		/>
	</div>
	{#if kind !== 'short'}
		<div class="results" id={listId} role="listbox" aria-label="Matching people">
			{#each items as person, i (person.uid)}
				<button
					type="button"
					id={`${id}-row-${i}`}
					role="option"
					aria-selected={i === active}
					class="row"
					class:on={i === active}
					onclick={() => choose(i)}
				>
					<span class="avatar">{initials(person.name, person.uid)}</span>
					<span class="text">
						<span class="name">{person.name ?? person.uid}</span>
						<span class="sub">{subline(person)}</span>
					</span>
				</button>
			{/each}
			{#if inviteRow}
				<button
					type="button"
					id={`${id}-row-${items.length}`}
					role="option"
					aria-selected={active === items.length}
					class="row"
					class:on={active === items.length}
					onclick={() => choose(items.length)}
				>
					<span class="avatar mail"><Mail size={16} strokeWidth={1.6} aria-hidden="true" /></span>
					<span class="text">
						<span class="name">Invite {query.trim().toLowerCase()}</span>
						<span class="sub">No account yet · they’ll get a link to sign up</span>
					</span>
				</button>
			{/if}
			<p class="hint" role="status">
				{#if searching}
					Searching…
				{:else if failed}
					We couldn’t search just now. Try again.
				{:else if noAccount && !allowInvite}
					No account uses this email. They need to join the network first.
				{:else if items.length === 0 && !inviteRow}
					{kind === 'email' && !INVITE_EMAIL_PATTERN.test(query.trim())
						? 'Type the full email address.'
						: 'No one matches.'}
				{:else}
					People in {networkName ?? 'your network'}.{allowInvite
						? ' Someone new? Type their full email.'
						: ''}
				{/if}
			</p>
		</div>
	{/if}
{/if}

<style>
	.search {
		display: flex;
		align-items: center;
		gap: 10px;
		height: 48px;
		padding-inline: 14px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: var(--color-canvas);
		color: var(--color-muted);
	}

	.search:focus-within {
		border-color: var(--color-accent);
	}

	.input {
		flex: 1;
		min-width: 0;
		height: 100%;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		outline: none;
	}

	.input::-webkit-search-cancel-button {
		display: none;
	}

	.results {
		display: flex;
		flex-direction: column;
		margin-top: 8px;
		padding: 4px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: var(--color-raised);
	}

	.row,
	.chosen {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 56px;
		padding-inline: 10px;
		border-radius: 10px;
		color: var(--color-text);
		text-align: left;
	}

	.row {
		border: 0;
		background: transparent;
		font: inherit;
		cursor: pointer;
	}

	.row.on,
	.row:hover {
		background: color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.chosen {
		padding-inline: 12px;
		border: 1px solid var(--color-border);
		border-radius: 14px;
		background: var(--color-canvas);
	}

	.avatar {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 32px;
		height: 32px;
		border-radius: var(--radius-pill);
		background: var(--color-border);
		color: var(--color-text);
		font-size: 11px;
		font-weight: var(--font-weight-semibold);
	}

	.avatar.mail {
		background: var(--color-accent-subtle);
		color: var(--color-accent);
	}

	.text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.name {
		overflow: hidden;
		font-size: 15px;
		line-height: 18px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.sub {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.clear {
		display: flex;
		align-items: center;
		justify-content: center;
		width: var(--hit-min);
		height: var(--hit-min);
		margin-right: -8px;
		border: 0;
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}

	.hint {
		padding: 8px 10px 6px;
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}
</style>
