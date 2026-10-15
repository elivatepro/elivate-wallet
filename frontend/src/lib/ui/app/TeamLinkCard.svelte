<!--
	The office's team link on the Invitations page (Slice 39; Paper "Team links
	v11" TL07/TL07d live, TL08 none yet or stopped). Live: the link, joined
	count, when it stops, Copy (Share on touch screens) and Manage. Otherwise a
	line about team links (or why the last one stopped) and "Make a team link".
	Manage and Make open the Invite dialog on its Team link tab.
-->
<script lang="ts">
	import { Effect, Exit } from 'effect';
	import Copy from '@lucide/svelte/icons/copy';
	import Link from '@lucide/svelte/icons/link';
	import Share from '@lucide/svelte/icons/share';
	import { AppRoutes } from '#lib/contract/app.js';
	import { TeamLinkRead, type TeamLink } from '#lib/contract/invitations.js';
	import { getJson } from '#lib/client/api.js';
	import {
		cardSummary,
		displayUrl,
		joinedLabel,
		STOPPED_TEXT,
		stopsLabel
	} from '#lib/team-links.js';

	let {
		office,
		refresh = 0,
		canAct,
		onManage
	}: {
		office: { officeId: string; name: string };
		/** Bumped by the page when the Invite dialog closes, to read the link again. */
		refresh?: number;
		canAct: boolean;
		onManage: () => void;
	} = $props();

	let link = $state<TeamLink | null>(null);
	let loaded = $state(false);
	let copied = $state(false);
	let copyFailed = $state(false);

	const live = $derived(link?.state === 'live' ? link : null);
	const canShare = $derived(
		typeof navigator !== 'undefined' &&
			'share' in navigator &&
			typeof matchMedia !== 'undefined' &&
			matchMedia('(pointer: coarse)').matches
	);

	async function load(officeId: string) {
		const exit = await Effect.runPromiseExit(
			getJson(AppRoutes.teamLink(officeId).path, TeamLinkRead)
		);
		if (officeId !== office.officeId) return;
		// A failed read keeps what was shown; the card is a shortcut, not the source.
		if (Exit.isSuccess(exit)) link = exit.value.link;
		loaded = true;
	}

	$effect(() => {
		void refresh;
		void load(office.officeId);
	});

	async function copy() {
		if (!live) return;
		try {
			await navigator.clipboard.writeText(live.url);
			copied = true;
			copyFailed = false;
			setTimeout(() => (copied = false), 2000);
		} catch {
			copyFailed = true;
		}
	}

	async function share() {
		if (!live) return;
		try {
			await navigator.share({ title: `Join ${office.name}`, url: live.url });
		} catch {
			// Closed the share sheet: nothing to do.
		}
	}
</script>

{#if loaded}
	<section class="card" class:live aria-labelledby="team-link-heading">
		<span class="icon" aria-hidden="true"><Link size={20} strokeWidth={2} /></span>
		<div class="text">
			<h2 id="team-link-heading">
				Team link
				{#if live}<span class="badge">Live</span>{/if}
			</h2>
			{#if live}
				<p class="url">{displayUrl(live.url)}</p>
				<p class="summary">{cardSummary(live)}</p>
			{:else if link}
				<p class="line">{STOPPED_TEXT[link.state as Exclude<TeamLink['state'], 'live'>]}</p>
			{:else}
				<p class="line">One link anyone can use to join {office.name} as a Member.</p>
			{/if}
		</div>
		{#if live}
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
			<div class="actions">
				{#if canShare}
					<button type="button" class="soft" onclick={share}>
						<Share size={16} aria-hidden="true" />Share
					</button>
				{:else}
					<button type="button" class="soft" onclick={copy}>
						<Copy size={16} aria-hidden="true" />{copied ? 'Copied' : 'Copy'}
					</button>
				{/if}
				<button type="button" class="outline" disabled={!canAct} onclick={onManage}>Manage</button>
			</div>
		{:else}
			<div class="actions">
				<button type="button" class="soft wide" disabled={!canAct} onclick={onManage}>
					Make a team link
				</button>
			</div>
		{/if}
		{#if copyFailed}
			<p class="copy-failed" role="alert">Copy didn’t work. Open Manage to select the link.</p>
		{/if}
	</section>
{/if}

<style>
	.card {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 14px 12px;
		padding: 16px;
		border-radius: 18px;
		border: 1px solid color-mix(in oklab, var(--color-text) 10%, transparent);
		background: var(--color-surface);
	}

	.icon {
		display: flex;
		flex-shrink: 0;
		align-items: center;
		justify-content: center;
		width: 40px;
		height: 40px;
		border-radius: 12px;
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

	h2 {
		display: flex;
		align-items: center;
		gap: 8px;
		margin: 0;
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
	}

	.badge {
		padding: 2px 8px;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--color-success) 16%, transparent);
		color: var(--color-success);
		font-size: 12px;
		font-weight: var(--font-weight-medium);
	}

	.url {
		display: none;
		overflow: hidden;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 13px;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.summary,
	.line {
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	.stats {
		display: none;
		margin: 0;
	}

	.actions {
		display: flex;
		flex-basis: 100%;
		gap: 10px;
	}

	.actions button {
		display: inline-flex;
		flex: 1;
		align-items: center;
		justify-content: center;
		gap: 6px;
		min-height: 44px;
		padding: 0 16px;
		border-radius: var(--radius-pill);
		font: inherit;
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		color: var(--color-text);
		cursor: pointer;
	}

	.soft {
		border: 0;
		background: var(--color-raised);
	}

	.outline {
		border: 1px solid color-mix(in oklab, var(--color-text) 20%, transparent);
		background: transparent;
	}

	.actions button:disabled {
		opacity: var(--opacity-disabled);
		cursor: default;
	}

	.copy-failed {
		flex-basis: 100%;
		color: var(--color-danger);
		font-size: 13px;
	}

	/* Paper TL07d: one row with the link, the figures and the buttons. */
	@media (min-width: 1024px) {
		.card {
			flex-wrap: nowrap;
			gap: 24px;
			padding: 20px 24px;
		}

		.icon {
			width: 44px;
			height: 44px;
		}

		h2 {
			font-size: 16px;
		}

		.card.live .url {
			display: block;
		}

		.card.live .summary {
			display: none;
		}

		.stats {
			display: flex;
			flex-shrink: 0;
			gap: 24px;
		}

		.stats div {
			display: flex;
			flex-direction: column;
			gap: 2px;
		}

		.stats div + div {
			padding-left: 24px;
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
			font-size: 16px;
			font-weight: var(--font-weight-semibold);
		}

		.actions {
			flex-basis: auto;
			flex-shrink: 0;
		}

		.actions button {
			flex: none;
			min-height: 40px;
		}
	}
</style>
