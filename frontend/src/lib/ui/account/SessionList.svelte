<!--
	Signed-in devices, Paper "App — Screens v2" S03 (desktop rows: icon tile,
	device, activity column, 200 px action lane) and S04 (mobile rows). Only
	what the backend returns is shown: no location or sign-in history yet
	(Blueprint 01 shows no IP). "This device" cannot be signed out here.
-->
<script lang="ts">
	import Laptop from '@lucide/svelte/icons/laptop';
	import Smartphone from '@lucide/svelte/icons/smartphone';
	import Tablet from '@lucide/svelte/icons/tablet';
	import type { SessionSummary } from '#lib/contract/security.js';
	import { activityLabel, describeDevice } from '#lib/devices.js';
	import RootDialog from './RootDialog.svelte';

	let {
		sessions,
		now,
		busy = null,
		disabled = false,
		heading,
		allOthersLabel = 'Sign out all others',
		onRevoke
	}: {
		sessions: ReadonlyArray<typeof SessionSummary.Type>;
		now: number;
		/** Session id being signed out, or 'all'. */
		busy?: string | null;
		disabled?: boolean;
		heading: string;
		allOthersLabel?: string;
		onRevoke: (target: { sessionId: string } | { allOthers: true }) => void;
	} = $props();

	const others = $derived(sessions.filter((s) => !s.current).length);
	/** Paper "App — Screens v4" Z07: confirm first; no PIN (owner decision 2026-10-08). */
	let confirming = $state(false);
	const askAllOthers = () => (confirming = true);
	const icons = { phone: Smartphone, tablet: Tablet, laptop: Laptop } as const;
</script>

<RootDialog
	bind:open={confirming}
	pose="dialog-sign-out"
	title={others === 1 ? 'Sign out 1 other device?' : `Sign out ${others} other devices?`}
	summary="This device stays signed in"
	confirmLabel="Sign out others"
	tone="danger"
	busy={busy !== null}
	onConfirm={() => {
		confirming = false;
		onRevoke({ allOthers: true });
	}}
/>

<section class="group" aria-labelledby="sessions-heading">
	<h2 class="eyebrow" id="sessions-heading">{heading}</h2>
	<div class="card">
		<div class="card-head">
			<h2 class="card-title">{heading}</h2>
			{#if others > 0}
				<button
					type="button"
					class="danger-pill"
					disabled={disabled || busy !== null}
					aria-busy={busy === 'all' ? 'true' : undefined}
					onclick={askAllOthers}>{allOthersLabel}</button
				>
			{/if}
		</div>
		<ul>
			{#each sessions as session (session.sessionId)}
				{@const device = describeDevice(session.userAgent)}
				{@const Icon = icons[device.kind]}
				<li class="row">
					<span class="icon" aria-hidden="true"><Icon size={20} strokeWidth={1.8} /></span>
					<span class="who">
						<span class="name">{device.label}</span>
						<span class="sub"
							><span class="mob">{activityLabel(session.lastActiveAt, now, {}, true)}</span><span
								class="desk"
								>Signed in {activityLabel(session.createdAt, now, {}, true) || 'recently'}</span
							></span
						>
					</span>
					<span class="activity">{activityLabel(session.lastActiveAt, now)}</span>
					<span class="lane">
						{#if session.current}
							<span class="badge">This device</span>
						{:else}
							<button
								type="button"
								class="pill"
								disabled={disabled || busy !== null}
								aria-busy={busy === session.sessionId ? 'true' : undefined}
								aria-label={`Sign out ${device.label}`}
								onclick={() => onRevoke({ sessionId: session.sessionId })}>Sign out</button
							>
						{/if}
					</span>
				</li>
			{/each}
		</ul>
	</div>
	{#if others > 0}
		<button
			type="button"
			class="danger-wide"
			disabled={disabled || busy !== null}
			onclick={askAllOthers}>{allOthersLabel}</button
		>
	{/if}
</section>

<style>
	.group {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.eyebrow {
		padding-left: 4px;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.06em;
		line-height: 14px;
		text-transform: uppercase;
	}

	.card {
		display: flex;
		flex-direction: column;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 18px;
		background: var(--color-surface);
	}

	:global([data-theme='light']) .card {
		border-color: var(--color-border);
	}

	.card-head {
		display: none;
	}

	ul {
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.row {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 14px 16px;
	}

	.row + .row {
		border-top: 1px solid #ffffff0a;
	}

	:global([data-theme='light']) .row + .row {
		border-top-color: var(--color-border);
	}

	.icon {
		display: flex;
		justify-content: center;
		flex-shrink: 0;
		width: 24px;
		color: var(--color-text);
	}

	.who {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 3px;
		min-width: 0;
	}

	.name {
		color: var(--color-text);
		font-size: 15px;
		line-height: 20px;
	}

	.sub {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.desk,
	.activity {
		display: none;
	}

	.lane {
		display: flex;
		flex-shrink: 0;
		justify-content: flex-end;
	}

	.badge {
		padding: 3px 10px;
		border-radius: var(--radius-pill);
		background: #1d2e26;
		color: var(--color-success);
		font-size: var(--text-12);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-16);
	}

	:global([data-theme='light']) .badge {
		background: color-mix(in oklab, var(--color-success) 12%, transparent);
	}

	.pill {
		display: flex;
		align-items: center;
		height: 34px;
		padding: 0 14px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-pill);
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-16);
		cursor: pointer;
	}

	.danger-wide,
	.danger-pill {
		border: 0;
		border-radius: var(--radius-pill);
		background: #3a1f1f;
		color: var(--color-danger);
		font: inherit;
		font-weight: var(--font-weight-medium);
		cursor: pointer;
	}

	:global([data-theme='light']) .danger-wide,
	:global([data-theme='light']) .danger-pill {
		background: color-mix(in oklab, var(--color-danger) 12%, transparent);
	}

	.danger-wide {
		height: 48px;
		font-size: 15px;
		line-height: 18px;
	}

	button:disabled {
		opacity: var(--opacity-disabled);
		cursor: not-allowed;
	}

	@media (min-width: 1024px) {
		.eyebrow,
		.danger-wide,
		.mob {
			display: none;
		}

		.card {
			border-radius: 20px;
		}

		.card-head {
			display: flex;
			align-items: center;
			justify-content: space-between;
			padding: 18px 22px;
			border-bottom: 1px solid #ffffff0f;
		}

		:global([data-theme='light']) .card-head {
			border-bottom-color: var(--color-border);
		}

		.card-title {
			color: var(--color-text);
			font-size: var(--text-16);
			font-weight: var(--font-weight-semibold);
			line-height: var(--leading-20);
		}

		.danger-pill {
			height: 36px;
			padding: 0 16px;
			font-size: 13px;
			line-height: var(--leading-16);
		}

		.row {
			gap: 16px;
			padding: 16px 22px;
		}

		.icon {
			align-items: center;
			width: 40px;
			height: 40px;
			border-radius: 10px;
			background: var(--color-raised);
		}

		.who {
			flex: 0 0 340px;
		}

		.name {
			font-size: var(--text-14);
			line-height: 18px;
		}

		.desk {
			display: inline;
		}

		.activity {
			display: block;
			flex: 1;
			color: var(--color-muted);
			font-size: 13px;
			line-height: var(--leading-16);
		}

		.lane {
			width: 200px;
		}
	}
</style>
