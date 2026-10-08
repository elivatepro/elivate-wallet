<!--
	Change role: MINIMAL STUB, waiting on Paper approval (Blueprint 07; W-05
	"classification"). No Paper composition exists yet. A role change ends the
	current membership and creates the new one in the same office (member <->
	the office's leader role), with a reason and the PIN. Replace with the
	approved design once drawn.
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import { AppOrgRoutes, MemberView } from '#lib/contract/org-admin.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import { LEADER_ROLE, personName } from '#lib/org.js';
	import { ROLE_LABELS } from '#lib/labels.js';
	import PinField from '#lib/ui/auth/PinField.svelte';

	const shell = getContext<Shell>('shell');
	const workspace = $derived(shell.state.kind === 'ready' ? shell.state.view.workspace : null);
	const id = $derived(page.params.id ?? '');
	let view = $state<MemberView | null>(null);
	let started = false;
	let reason = $state('');
	let done = $state(false);
	const change = new OrgCommand();

	$effect(() => {
		if (shell.state.kind === 'ready' && !started) {
			started = true;
			void loadView(AppOrgRoutes.member(id), MemberView).then((r) => {
				if (r.ok) view = r.value;
			});
		}
	});

	const member = $derived(view?.member ?? null);
	const target = $derived.by(() => {
		if (!member?.office) return null;
		return member.role === 'member' ? LEADER_ROLE[member.office.type] : 'member';
	});

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		if (!workspace || !target) return;
		const pin = String(new FormData(event.currentTarget as HTMLFormElement).get('pin') ?? '');
		if (reason.trim().length < 3) {
			change.error = 'Give a reason (3–500 characters).';
			return;
		}
		done = !!(await change.send(
			AppOrgRoutes.memberAction(id, 'role'),
			'POST',
			{ role: target, reason: reason.trim(), ...(pin ? { pin } : {}) },
			workspace.membershipId
		));
	}
</script>

<svelte:head><title>Change role · Elivate Wallet</title></svelte:head>

<div class="o-page stub">
	<a class="o-sub" href={`/app/members/${id}`}>Back to the member</a>
	<h1>Change role</h1>
	{#if done}
		<p class="o-notice" role="status">
			Role changed. The old membership ended and a new one started.
		</p>
		<a class="o-ghost" href="/app/members">Back to members</a>
	{:else if member && target && member.actions.changeRole}
		<p class="o-sub">
			{personName(member.person)} · {member.office?.name}: {ROLE_LABELS[member.role]} → {ROLE_LABELS[
				target
			]}
		</p>
		<form class="o-card o-card-pad" onsubmit={submit} novalidate>
			{#if change.error}<p class="o-field-error" role="alert">{change.error}</p>{/if}
			<div class="o-field">
				<label for="role-reason">Reason</label>
				<textarea id="role-reason" class="o-input" maxlength="500" bind:value={reason}></textarea>
			</div>
			<PinField id="role-pin" name="pin" label="Your PIN" error={change.pinError} />
			<button class="o-primary" type="submit" disabled={change.busy || !shell.canAct}
				>Make {ROLE_LABELS[target]}</button
			>
		</form>
	{:else if view}
		<p class="o-sub">You can’t change this membership’s role.</p>
	{/if}
</div>

<style>
	.stub {
		max-width: 560px;
	}

	h1 {
		font-size: var(--text-24);
		font-weight: var(--font-weight-semibold);
	}

	.o-primary {
		align-self: flex-start;
	}
</style>
