<!--
	Close office: MINIMAL STUB, waiting on Paper approval (Blueprint 07). No
	Paper composition exists yet; this page only wires the approved command
	(President Team, reason + PIN; only an office with no open child offices
	and no members other than its leaders closes). Replace with the approved
	design once drawn.
-->
<script lang="ts">
	import '#lib/ui/org/org.css';
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import { AppOrgRoutes, OfficeView } from '#lib/contract/org-admin.js';
	import { loadView, OrgCommand } from '#lib/client/org.svelte.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import PinField from '#lib/ui/auth/PinField.svelte';

	const shell = getContext<Shell>('shell');
	const workspace = $derived(shell.state.kind === 'ready' ? shell.state.view.workspace : null);
	const id = $derived(page.params.id ?? '');
	let name = $state<string | null>(null);
	let started = false;
	let reason = $state('');
	let done = $state(false);
	const close = new OrgCommand();

	$effect(() => {
		if (shell.state.kind === 'ready' && !started) {
			started = true;
			void loadView(AppOrgRoutes.office(id), OfficeView).then((r) => {
				if (r.ok) name = r.value.office.name;
			});
		}
	});

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		if (!workspace) return;
		const pin = String(new FormData(event.currentTarget as HTMLFormElement).get('pin') ?? '');
		if (reason.trim().length < 3) {
			close.error = 'Give a reason (3–500 characters).';
			return;
		}
		done = await close.send(
			AppOrgRoutes.officeClose(id),
			'POST',
			{ reason: reason.trim(), ...(pin ? { pin } : {}) },
			workspace.membershipId
		);
	}
</script>

<svelte:head><title>Close office · Elivate Wallet</title></svelte:head>

<div class="o-page stub">
	<a class="o-sub" href={`/app/offices/${id}`}>Back to the office</a>
	<h1>Close {name ?? 'office'}</h1>
	{#if done}
		<p class="o-notice" role="status">The office is closed. Its money stays visible above it.</p>
		<a class="o-ghost" href="/app/offices">Back to offices</a>
	{:else}
		<p class="o-sub">
			Only an office with no open offices under it and no members besides its leaders can close. Its
			leaders’ memberships end and pending invitations are revoked.
		</p>
		<form class="o-card o-card-pad" onsubmit={submit} novalidate>
			{#if close.error}<p class="o-field-error" role="alert">{close.error}</p>{/if}
			<div class="o-field">
				<label for="close-reason">Reason</label>
				<textarea id="close-reason" class="o-input" maxlength="500" bind:value={reason}></textarea>
			</div>
			<PinField id="close-pin" name="pin" label="Your PIN" error={close.pinError} />
			<button class="o-ghost danger" type="submit" disabled={close.busy || !shell.canAct}
				>Close office</button
			>
		</form>
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

	.danger {
		align-self: flex-start;
		color: var(--color-danger);
	}
</style>
