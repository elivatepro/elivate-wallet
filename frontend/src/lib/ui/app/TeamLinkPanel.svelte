<!--
	The Invite dialog's "Team link" tab (Blueprint 38; Paper "Team links v11"
	TL01/TL01d make a link, TL02/TL02d the live link, TL06/TL06d the pickers).
	One live link per office: making a new one replaces it. Creating and turning
	off always confirm with the PIN ("You'll confirm with your PIN"); the
	backend's step-up decides, so an expired proof also asks again.
-->
<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { Cause, Effect, Exit, Option } from 'effect';
	import Copy from '@lucide/svelte/icons/copy';
	import Link from '@lucide/svelte/icons/link';
	import { AppRoutes, type InviteOffice } from '#lib/contract/app.js';
	import type { ApiFailure } from '#lib/contract/errors.js';
	import {
		CreatedTeamLink,
		TeamLinkRead,
		TurnedOffTeamLink,
		type TeamLink
	} from '#lib/contract/invitations.js';
	import { getJson, newKey, sendCommand } from '#lib/client/api.js';
	import { followGate } from '#lib/client/account.js';
	import { keepsKey, shortDate } from '#lib/invitations.js';
	import {
		DAYS_OPTIONS,
		DEFAULT_DAYS,
		DEFAULT_USES,
		STOPPED_TEXT,
		USES_OPTIONS,
		daysValue,
		describeTeamLinkFailure,
		displayUrl,
		joinedLabel,
		stopsLabel,
		usesValue
	} from '#lib/team-links.js';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';
	import { enterMovesOn } from '#lib/ui/enter-moves-on.js';

	let {
		offices,
		officeId = $bindable(),
		membershipId,
		canAct
	}: {
		offices: ReadonlyArray<InviteOffice>;
		officeId: string;
		/** The selected workspace, echoed with every command. */
		membershipId: string;
		canAct: boolean;
	} = $props();

	const office = $derived(offices.find((o) => o.officeId === officeId) ?? offices[0]);

	type Mode = 'loading' | 'failed' | 'form' | 'live';
	let mode = $state<Mode>('loading');
	let link = $state<TeamLink | null>(null);
	let loadError = $state<string | null>(null);
	let days = $state<string>(DEFAULT_DAYS);
	let uses = $state<string>(DEFAULT_USES);
	/** The PIN step of "Create link" or "Turn off". */
	let confirming = $state<'create' | 'turn-off' | null>(null);
	let busy = $state(false);
	let error = $state<string | null>(null);
	let pinError = $state<string | null>(null);
	let copied = $state(false);
	let createKey = newKey();
	let turnOffKey = newKey();

	const live = $derived(link?.state === 'live' ? link : null);
	const canShare = $derived(
		typeof navigator !== 'undefined' &&
			'share' in navigator &&
			typeof matchMedia !== 'undefined' &&
			matchMedia('(pointer: coarse)').matches
	);

	const failureOf = <A,>(exit: Exit.Exit<A, ApiFailure>) =>
		Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) : undefined;

	async function load(id: string) {
		mode = 'loading';
		loadError = null;
		confirming = null;
		error = null;
		const exit = await Effect.runPromiseExit(getJson(AppRoutes.teamLink(id).path, TeamLinkRead));
		if (id !== office?.officeId) return;
		if (Exit.isSuccess(exit)) {
			link = exit.value.link;
			mode = link?.state === 'live' ? 'live' : 'form';
			return;
		}
		const failure = failureOf(exit);
		if (followGate(failure, '/app/invitations')) return;
		loadError =
			failure?._tag === 'BackendError' ? failure.message : 'We couldn’t load the team link.';
		mode = 'failed';
	}

	$effect(() => {
		if (office) void load(office.officeId);
	});

	function newLink() {
		days = DEFAULT_DAYS;
		uses = DEFAULT_USES;
		error = null;
		confirming = null;
		mode = 'form';
	}

	function failed(action: 'create' | 'turn-off', failure: ApiFailure | undefined) {
		const said = describeTeamLinkFailure(action, failure);
		if (said.kind === 'locked') window.location.assign('/pin/locked');
		else if (said.kind === 'pin') pinError = said.text;
		else error = said.text;
	}

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		if (!office || busy) return;
		const action = mode === 'live' ? 'turn-off' : 'create';
		if (confirming !== action) {
			confirming = action;
			error = null;
			pinError = null;
			return;
		}
		const pin = String(new FormData(event.currentTarget as HTMLFormElement).get('pin') ?? '');
		if (!/^[0-9]{4}$/.test(pin)) {
			pinError = 'Enter your 4-digit PIN.';
			return;
		}
		if (!canAct) return;
		busy = true;
		error = null;
		pinError = null;
		if (action === 'create') {
			const exit = await Effect.runPromiseExit(
				sendCommand(
					AppRoutes.createTeamLink.path,
					'POST',
					{
						officeId: office.officeId,
						days: daysValue(days),
						maxUses: usesValue(uses),
						pin,
						idempotencyKey: createKey
					},
					membershipId,
					CreatedTeamLink
				)
			);
			busy = false;
			if (Exit.isSuccess(exit)) {
				createKey = newKey();
				// The office changed meanwhile: show that office's own link.
				if (exit.value.officeId !== office?.officeId) {
					if (office) void load(office.officeId);
					return;
				}
				link = exit.value;
				confirming = null;
				mode = 'live';
				return;
			}
			const failure = failureOf(exit);
			if (!keepsKey(failure)) createKey = newKey();
			failed('create', failure);
			return;
		}
		if (!live) return;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				AppRoutes.turnOffTeamLink(live.teamLinkId).path,
				'POST',
				{ pin, idempotencyKey: turnOffKey },
				membershipId,
				TurnedOffTeamLink
			)
		);
		busy = false;
		if (Exit.isSuccess(exit)) {
			turnOffKey = newKey();
			link = null;
			newLink();
			return;
		}
		const failure = failureOf(exit);
		if (!keepsKey(failure)) turnOffKey = newKey();
		failed('turn-off', failure);
	}

	async function copy() {
		if (!live) return;
		try {
			await navigator.clipboard.writeText(live.url);
			copied = true;
			setTimeout(() => (copied = false), 2000);
		} catch {
			error = 'Copy didn’t work. Select the link and copy it.';
		}
	}

	async function share() {
		if (!live || !office) return;
		try {
			await navigator.share({ title: `Join ${office.name}`, url: live.url });
		} catch {
			// Closed the share sheet: nothing to do.
		}
	}
</script>

<form onsubmit={submit} novalidate {@attach enterMovesOn}>
	<div class="body">
		{#if error}<p class="error" role="alert">{error}</p>{/if}

		{#if offices.length > 1 && mode !== 'live'}
			<label class="label" for="team-office">Office</label>
			<div class="pick">
				<WheelPicker
					id="team-office"
					label="Office"
					options={offices.map((o) => ({ value: o.officeId, label: o.name }))}
					value={officeId}
					disabled={busy}
					onchange={(id) => (officeId = id)}
				/>
			</div>
		{/if}

		{#if mode === 'loading'}
			<p class="quiet" aria-live="polite">Loading the team link…</p>
		{:else if mode === 'failed'}
			<p class="error" role="alert">{loadError}</p>
			<button class="text-button" type="button" onclick={() => office && load(office.officeId)}>
				Try again
			</button>
		{:else if mode === 'form'}
			{#if link && link.state !== 'live'}
				<p class="quiet">{STOPPED_TEXT[link.state]}</p>
			{/if}
			<label class="label" for="team-days">Link works for</label>
			<div class="pick">
				<WheelPicker
					id="team-days"
					label="Link works for"
					sub="After this the link stops working."
					options={DAYS_OPTIONS}
					value={days}
					onchange={(value) => (days = value)}
				/>
			</div>
			<label class="label" for="team-uses">People who can join</label>
			<div class="pick">
				<WheelPicker
					id="team-uses"
					label="People who can join"
					sub="How many people this link can add. The link stops when it’s full."
					options={USES_OPTIONS}
					value={uses}
					onchange={(value) => (uses = value)}
				/>
			</div>
			<p class="note">
				<Link size={18} aria-hidden="true" />
				<span>
					Anyone with this link joins {office?.name} as a Member right away.
					{#if live}Your current link stops working.{/if}
					You’ll confirm with your PIN.
				</span>
			</p>
		{:else if live}
			<p class="label">Your team link</p>
			<div class="link-box">
				<span class="url">{displayUrl(live.url)}</span>
				<button class="copy" type="button" onclick={copy}>
					<Copy size={16} aria-hidden="true" />
					{copied ? 'Copied' : 'Copy'}
				</button>
			</div>
			<dl class="stats">
				<div>
					<dt>Joined</dt>
					<dd>{joinedLabel(live)}</dd>
				</div>
				<div>
					<dt>Stops working</dt>
					<dd>{stopsLabel(live.expiresAt)}</dd>
				</div>
			</dl>
			<div class="secondary">
				<button class="text-button" type="button" onclick={newLink}>Make a new link</button>
				<span class="quiet">
					{#if live.createdBy}Made by {live.createdBy.name ?? live.createdBy.uid} ·{/if}
					{shortDate(live.createdAt)}
				</span>
			</div>
		{/if}

		{#if confirming}
			<PinField id="team-pin" name="pin" label="Your PIN" error={pinError} autofocus />
		{/if}
	</div>

	<div class="actions">
		{#if mode === 'live'}
			<button class="confirm-cancel danger" type="submit" disabled={busy} aria-busy={busy}>
				{confirming === 'turn-off' ? 'Turn off link' : 'Turn off'}
			</button>
			{#if confirming !== 'turn-off' && canShare}
				<button class="go" type="button" onclick={share}>Share link</button>
			{:else if confirming !== 'turn-off'}
				<Dialog.Close class="go" type="button">Done</Dialog.Close>
			{/if}
		{:else}
			{#if link?.state === 'live'}
				<button class="confirm-cancel" type="button" onclick={() => (mode = 'live')}>Back</button>
			{:else}
				<Dialog.Close class="confirm-cancel" type="button">Cancel</Dialog.Close>
			{/if}
			{#if mode === 'form'}
				<button class="go" type="submit" disabled={busy || !office} aria-busy={busy}>
					Create link
				</button>
			{/if}
		{/if}
	</div>
</form>

<style>
	.body {
		display: flex;
		flex-direction: column;
		gap: 10px;
		/* Header (150) + tabs (70) + actions (90) stay on screen; the body scrolls. */
		max-height: max(160px, calc(100dvh - 330px - env(safe-area-inset-bottom)));
		overflow-y: auto;
		padding: 0 28px 28px;
	}

	@media (min-width: 1024px) {
		.body {
			/* The desktop card sits 150 px from the top. */
			max-height: max(160px, min(640px, calc(100dvh - 500px)));
		}
	}

	.error {
		padding: 10px 14px;
		border-radius: var(--radius-12);
		background: color-mix(in oklab, var(--color-danger) 12%, transparent);
		color: var(--color-text);
		font-size: var(--text-14);
	}

	.label {
		margin-top: 8px;
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
	}

	.quiet {
		color: var(--color-muted);
		font-size: 13px;
	}

	.pick :global(.wp-trigger) {
		min-height: 48px;
		padding: 0 16px;
		border-radius: var(--radius-12);
		border: 1px solid color-mix(in oklab, var(--color-text) 16%, transparent);
		background: color-mix(in oklab, var(--color-canvas) 60%, transparent);
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
	}

	.pick :global(.wp-trigger:focus) {
		outline: none;
		border-color: var(--color-accent);
	}

	.note {
		display: flex;
		align-items: flex-start;
		gap: 10px;
		margin-top: 8px;
		padding: 12px 14px;
		border-radius: 14px;
		background: var(--color-accent-subtle);
		color: var(--color-text);
		font-size: 13px;
		line-height: 18px;
	}

	.note :global(svg) {
		flex-shrink: 0;
		color: var(--color-accent);
	}

	.link-box {
		display: flex;
		align-items: center;
		gap: 12px;
		min-height: 56px;
		padding: 0 8px 0 16px;
		border-radius: 14px;
		border: 1px dashed color-mix(in oklab, var(--color-text) 24%, transparent);
		background: color-mix(in oklab, var(--color-canvas) 60%, transparent);
	}

	.url {
		flex: 1;
		min-width: 0;
		overflow: hidden;
		font-family: var(--font-mono);
		font-size: 13px;
		text-overflow: ellipsis;
		white-space: nowrap;
		user-select: all;
	}

	.copy {
		display: flex;
		flex-shrink: 0;
		align-items: center;
		gap: 6px;
		height: 40px;
		padding: 0 14px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--color-raised);
		color: var(--color-text);
		font: inherit;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		cursor: pointer;
	}

	.stats {
		display: flex;
		margin: 0;
		border-radius: 14px;
		border: 1px solid color-mix(in oklab, var(--color-text) 10%, transparent);
	}

	.stats div {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 4px;
		padding: 14px 16px;
	}

	.stats div + div {
		border-left: 1px solid color-mix(in oklab, var(--color-text) 10%, transparent);
	}

	.stats dt {
		color: var(--color-muted);
		font-size: 12px;
		letter-spacing: var(--tracking-label);
		text-transform: uppercase;
	}

	.stats dd {
		margin: 0;
		font-size: 20px;
		font-weight: var(--font-weight-semibold);
		line-height: 24px;
	}

	.secondary {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
	}

	.text-button {
		align-self: flex-start;
		padding: 0;
		border: 0;
		background: none;
		color: var(--color-accent);
		font: inherit;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		text-decoration: underline;
		cursor: pointer;
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 12px;
		padding: 20px 28px;
		border-top: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
	}

	.danger {
		color: var(--color-danger);
	}

	.actions :global(.go) {
		min-height: 48px;
		padding: 0 22px;
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--button-primary-bg);
		box-shadow: var(--auth-button-shadow);
		color: var(--button-primary-ink);
		font: inherit;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.actions :global(.go:disabled) {
		opacity: var(--opacity-disabled);
	}

	@media (max-width: 639px) {
		.actions > :global(*) {
			flex: 1;
		}
	}
</style>
