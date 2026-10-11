<!--
	President Team: MINIMAL STUB, waiting on Paper approval (Blueprint 07; W-05
	Q5). No Paper composition exists yet. Only President Team Members add or
	remove President Team Members, with a reason and the PIN; one always
	remains and nobody removes themselves. Replace with the approved design.
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext } from 'svelte';
	import { UID_PATTERN } from '#lib/contract/common.js';
	import { AppOrgRoutes, MemberRows, type MemberRow } from '#lib/contract/org-admin.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import { cachedPage } from '#lib/client/page-cache.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { personName } from '#lib/org.js';
	import CacheNote from '#lib/ui/app/CacheNote.svelte';
	import PinField from '#lib/ui/auth/PinField.svelte';

	const shell = getContext<Shell>('shell');
	const workspace = $derived(shell.state.kind === 'ready' ? shell.state.view.workspace : null);
	// Blueprint 23: the President Team list opens from cache, then refreshes.
	const view = cachedPage(shell, {
		kind: 'members',
		part: () => 'presidents',
		load: () => loadView(`${AppOrgRoutes.members}?role=president_team_member`, MemberRows)
	});
	const items = $derived(view.data?.items ?? null);
	const loadError = $derived(view.data ? null : view.error);
	let uid = $state('');
	let reason = $state('');
	let removing = $state<MemberRow | null>(null);
	let notice = $state<string | null>(null);
	const command = new OrgCommand();

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		if (!workspace) return;
		const pin = String(new FormData(event.currentTarget as HTMLFormElement).get('pin') ?? '');
		if (reason.trim().length < 3) {
			command.error = 'Give a reason (3–500 characters).';
			return;
		}
		const body = { reason: reason.trim(), ...(pin ? { pin } : {}) };
		let ok: boolean;
		if (removing) {
			ok = !!(await command.send(
				AppOrgRoutes.presidentRemove(removing.membershipId),
				'POST',
				body,
				workspace.membershipId
			));
		} else {
			if (!UID_PATTERN.test(uid.trim().toUpperCase())) {
				command.error = 'Enter the person’s UID (EW-…).';
				return;
			}
			ok = !!(await command.send(
				AppOrgRoutes.presidents,
				'POST',
				{ ...body, memberUid: uid.trim().toUpperCase() },
				workspace.membershipId
			));
		}
		if (ok) {
			notice = removing ? 'Removed from the President Team.' : 'Added to the President Team.';
			removing = null;
			uid = '';
			reason = '';
			await view.reload();
		}
	}
</script>

<svelte:head><title>President Team · Elivate Wallet</title></svelte:head>

<div class="o-page stub">
	<a class="o-sub" href="/app/access">Back to roles & access</a>
	<h1>President Team</h1>
	<CacheNote savedAt={view.savedAt} online={shell.online} failed={view.error !== null} />
	{#if notice}<p class="o-notice" role="status">{notice}</p>{/if}
	{#if loadError}
		<p class="o-error" role="alert">{loadError}</p>
	{:else if items}
		<ul class="o-card o-rows">
			{#each items as member (member.membershipId)}
				<li class="o-row">
					<span class="o-stack o-grow">
						<span class="o-title">{personName(member.person)}</span>
						<span class="o-sub">{member.person?.uid ?? ''}</span>
					</span>
					{#if member.membershipId !== workspace?.membershipId}
						<button
							type="button"
							class="o-ghost"
							onclick={() => {
								command.reset(member.membershipId);
								removing = member;
							}}>Remove</button
						>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}
	<form class="o-card o-card-pad" onsubmit={submit} novalidate>
		<h2>{removing ? `Remove ${personName(removing.person)}` : 'Add a President Team Member'}</h2>
		{#if command.error}<p class="o-field-error" role="alert">{command.error}</p>{/if}
		{#if !removing}
			<div class="o-field">
				<label for="pt-uid">UID</label>
				<input id="pt-uid" class="o-input o-mono" placeholder="EW-00000" bind:value={uid} />
			</div>
		{/if}
		<div class="o-field">
			<label for="pt-reason">Reason</label>
			<textarea id="pt-reason" class="o-input" maxlength="500" bind:value={reason}></textarea>
		</div>
		<PinField id="pt-pin" name="pin" label="Your PIN" error={command.pinError} />
		<div class="row">
			<button class="o-primary" type="submit" disabled={command.busy || !shell.canAct}
				>{removing ? 'Remove' : 'Add'}</button
			>
			{#if removing}<button type="button" class="o-ghost" onclick={() => (removing = null)}
					>Cancel</button
				>{/if}
		</div>
	</form>
</div>

<style>
	.stub {
		max-width: 640px;
	}

	h1 {
		font-size: var(--text-24);
		font-weight: var(--font-weight-semibold);
	}

	h2 {
		font-size: var(--text-16);
		font-weight: var(--font-weight-semibold);
	}

	.row {
		display: flex;
		gap: 12px;
	}
</style>
