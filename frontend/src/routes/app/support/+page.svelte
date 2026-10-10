<!--
	Support & help (Blueprint 17, W-21): Paper "App — Screens v1" E11 (desktop)
	and E12 (mobile); Start a chat opens Elivate's Chatwoot panel (Paper v4
	WK01), loaded only on that press. Help topics are left out until a help
	site exists (never show content that isn't there). The network's support
	contact (team settings) and Elivate's app help stay separate and labelled.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import MessageCircle from '@lucide/svelte/icons/message-circle';
	import { chatScreen, openSupportChat, SUPPORT_EMAIL } from '#lib/client/chat.js';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import PageBar from '#lib/ui/account/PageBar.svelte';
	import RootImage from '#lib/ui/RootImage.svelte';

	const shell = getContext<Shell>('shell');

	const summary = $derived(
		shell.state.kind === 'ready' || shell.state.kind === 'offline' ? shell.state.summary : null
	);
	/** "Lagos office · Elivate Network" (E11 hero subtitle). */
	const place = $derived(
		summary ? [summary.officeName, summary.tenantName].filter(Boolean).join(' · ') : null
	);
	const uid = $derived(shell.state.kind === 'ready' ? shell.state.view.state.uid : null);
	const brand = $derived(shell.state.kind === 'ready' ? (shell.state.view.brand ?? null) : null);

	/** Network contact: loading, not readable, not added yet, or the contact. */
	const network = $derived.by(() => {
		if (shell.state.kind === 'loading') return { kind: 'loading' as const };
		if (!brand) return { kind: 'error' as const };
		const support = brand.support;
		const helpUrl = httpsUrl(support?.helpUrl ?? null);
		if (!support || (!support.email && !support.phone && !helpUrl)) {
			return { kind: 'none' as const, name: brand.name };
		}
		return {
			kind: 'contact' as const,
			title: support.name?.trim() || `${brand.name} support`,
			email: support.email,
			phone: support.phone,
			helpUrl
		};
	});

	/** Only an https help site is linked; shown by its host name. */
	function httpsUrl(value: string | null): URL | null {
		if (!value) return null;
		try {
			const url = new URL(value);
			return url.protocol === 'https:' ? url : null;
		} catch {
			return null;
		}
	}

	let chat = $state<'idle' | 'opening' | 'unavailable'>('idle');

	async function startChat() {
		if (chat === 'opening') return;
		chat = 'opening';
		const opened = await openSupportChat(chatScreen(page.route.id));
		chat = opened ? 'idle' : 'unavailable';
	}
</script>

<svelte:head><title>Support · Elivate Wallet</title></svelte:head>

<PageBar title="Support" back="/app/more" backLabel="Back to More" />

{#snippet chatButton(where: 'hero' | 'dock')}
	<button
		type="button"
		class="chat-button at-{where}"
		onclick={startChat}
		disabled={chat === 'opening'}
		aria-busy={chat === 'opening'}
	>
		{#if where === 'hero'}<MessageCircle size={16} strokeWidth={2} aria-hidden="true" />{/if}
		{chat === 'opening' ? 'Opening chat…' : 'Start a chat'}
	</button>
{/snippet}

<div class="support">
	<section class="hero" aria-labelledby="support-title">
		<div class="shade" aria-hidden="true"></div>
		<div class="grain" aria-hidden="true"></div>
		<RootImage pose="support" class="hero-root" sizes="(min-width: 1024px) 176px, 112px" eager />
		<div class="hero-text">
			<h1 id="support-title" tabindex="-1">How can we help?</h1>
			{#if place}<p class="place">{place}</p>{/if}
		</div>
		{@render chatButton('hero')}
	</section>

	<p class="chat-status" role="status">
		{#if chat === 'unavailable'}
			Chat isn’t available right now. Email
			<a href="mailto:{SUPPORT_EMAIL}">{SUPPORT_EMAIL}</a>.
		{/if}
	</p>

	<div class="contacts">
		<section class="card" aria-labelledby="network-title">
			<p class="label">Your network</p>
			<div class="head">
				<h2 id="network-title">
					{network.kind === 'contact' ? network.title : 'Network support'}
				</h2>
				<p class="sub">For income, withdrawals and your team</p>
			</div>
			{#if network.kind === 'loading'}
				<p class="note">Loading your network’s contact…</p>
			{:else if network.kind === 'error'}
				<p class="note">We couldn’t load your network’s support contact. Try again later.</p>
			{:else if network.kind === 'none'}
				<p class="note">Your network hasn’t added a support contact yet.</p>
			{:else}
				<dl class="rows">
					{#if network.email}
						<div class="row">
							<dt>Email</dt>
							<dd><a href="mailto:{network.email}">{network.email}</a></dd>
						</div>
					{/if}
					{#if network.phone}
						<div class="row">
							<dt>Phone</dt>
							<!-- The network's shared support line: shown in full so members can call it. -->
							<dd><a href="tel:{network.phone}">{network.phone}</a></dd>
						</div>
					{/if}
					{#if network.helpUrl}
						<div class="row">
							<dt>Help website</dt>
							<dd>
								<a href={network.helpUrl.href} target="_blank" rel="noopener noreferrer"
									>{network.helpUrl.host}<span class="visually-hidden">
										(opens in a new tab)</span
									></a
								>
							</dd>
						</div>
					{/if}
				</dl>
			{/if}
		</section>

		<section class="card" aria-labelledby="app-title">
			<p class="label">Elivate Wallet</p>
			<div class="head">
				<h2 id="app-title">App help</h2>
				<p class="sub">For sign-in, security and app problems</p>
			</div>
			<dl class="rows">
				<div class="row">
					<dt>Email</dt>
					<dd><a href="mailto:{SUPPORT_EMAIL}">{SUPPORT_EMAIL}</a></dd>
				</div>
				{#if uid}
					<div class="row">
						<dt>Your UID</dt>
						<dd class="uid">{uid}</dd>
					</div>
				{/if}
			</dl>
		</section>
	</div>

	<div class="dock">{@render chatButton('dock')}</div>
</div>

<style>
	.support {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	/* ── Hero (E12 mobile 150 px, E11 desktop 220 px); brand surface in both themes ── */

	.hero {
		position: relative;
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		gap: 24px;
		height: 150px;
		padding: 20px;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 20px;
		background-color: #1a1d1e;
		background-image: url('/auth-bg/mobile-dark.jpg');
		background-size: cover;
		background-position: 50% 30%;
		background-origin: border-box;
		isolation: isolate;
	}

	.shade,
	.grain {
		position: absolute;
		inset: 0;
		pointer-events: none;
	}

	.shade {
		background-image: linear-gradient(
			in oklab 90deg,
			oklab(18.5% -0.002 -0.003 / 92%) 0%,
			oklab(18.5% -0.002 -0.003 / 50%) 60%,
			oklab(18.5% -0.002 -0.003 / 0%) 100%
		);
	}

	.grain {
		background-image: url('/auth-bg/grain-256.png');
		background-size: 256px 256px;
		background-repeat: repeat;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}

	.hero :global(.hero-root) {
		position: absolute;
		right: 18px;
		bottom: -10px;
		width: 112px;
		height: 150px;
	}

	.hero-text {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 8px;
		max-width: calc(100% - 130px);
	}

	h1 {
		color: #f2f4f4;
		font-size: 18px;
		font-weight: var(--font-weight-semibold);
		letter-spacing: -0.01em;
		line-height: 24px;
		outline: none;
	}

	.place {
		display: none;
		color: #a9b0b3;
		font-size: 14px;
		line-height: 20px;
	}

	/* ── Start a chat ── */

	.chat-button {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		min-height: var(--hit-min);
		border: 0;
		border-radius: var(--radius-pill);
		background: var(--button-primary-bg);
		box-shadow:
			#ffffff59 0px 1px 0px inset,
			var(--button-primary-glow) 0px 10px 28px -10px;
		color: var(--button-primary-ink);
		font: inherit;
		font-weight: var(--font-weight-semibold);
		cursor: pointer;
	}

	.chat-button:disabled {
		opacity: var(--opacity-disabled);
		cursor: progress;
	}

	.chat-button:focus-visible,
	a:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: 3px;
	}

	.chat-button.at-hero {
		display: none;
	}

	.dock {
		display: flex;
		padding-top: 4px;
	}

	.chat-button.at-dock {
		flex: 1;
		height: 52px;
		font-size: 15px;
		line-height: 18px;
	}

	.chat-status:empty {
		display: none;
	}

	.chat-status {
		padding: 12px 16px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-16);
		background: var(--color-surface);
		color: var(--color-text);
		font-size: 14px;
		line-height: 20px;
	}

	/* ── Contacts: one grouped list on mobile (E12), two cards on desktop (E11) ── */

	.contacts {
		display: flex;
		flex-direction: column;
		border: 1px solid var(--color-border);
		border-radius: 18px;
		background: var(--color-surface);
	}

	.card {
		display: flex;
		flex-direction: column;
		gap: 10px;
		min-width: 0;
		padding: 14px 16px;
	}

	.card + .card {
		border-top: 1px solid var(--color-border);
	}

	.label {
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 11px;
		letter-spacing: 0.08em;
		line-height: 14px;
		text-transform: uppercase;
	}

	.head {
		display: flex;
		flex-direction: column;
		gap: 4px;
		margin-top: -8px;
	}

	h2 {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
	}

	.sub,
	.note {
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	.note {
		color: var(--color-text);
	}

	.rows {
		display: flex;
		flex-direction: column;
	}

	.row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		min-height: var(--hit-min);
	}

	dt {
		flex-shrink: 0;
		color: var(--color-muted);
		font-size: 14px;
		line-height: 18px;
	}

	dd {
		min-width: 0;
		color: var(--color-text);
		font-size: 14px;
		line-height: 18px;
		text-align: right;
		overflow-wrap: anywhere;
	}

	dd a,
	.chat-status a {
		display: inline-flex;
		align-items: center;
		min-height: var(--hit-min);
		color: var(--color-accent-text);
		text-decoration: underline;
		text-decoration-color: color-mix(in srgb, currentColor 45%, transparent);
		text-underline-offset: 3px;
	}

	.chat-status a {
		min-height: 0;
	}

	.uid {
		font-family: var(--font-mono);
		font-size: 13px;
		line-height: 16px;
	}

	.visually-hidden {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip-path: inset(50%);
		white-space: nowrap;
	}

	@media (min-width: 1024px) {
		.support {
			gap: 32px;
		}

		.hero {
			justify-content: space-between;
			align-items: flex-start;
			height: 220px;
			padding: 32px;
			border-radius: var(--radius-24);
		}

		.shade {
			background-image: linear-gradient(
				in oklab 90deg,
				oklab(18.5% -0.002 -0.003 / 92%) 0%,
				oklab(18.5% -0.002 -0.003 / 55%) 55%,
				oklab(18.5% -0.002 -0.003 / 0%) 100%
			);
		}

		.hero :global(.hero-root) {
			right: 56px;
			bottom: -14px;
			width: 176px;
			height: 236px;
		}

		.hero-text {
			max-width: calc(100% - 260px);
		}

		h1 {
			font-size: 32px;
			letter-spacing: -0.02em;
			line-height: 40px;
		}

		.place {
			display: block;
		}

		.chat-button.at-hero {
			position: relative;
			display: inline-flex;
			height: 44px;
			padding: 0 20px 0 16px;
			font-size: 14px;
			line-height: 18px;
		}

		.dock {
			display: none;
		}

		.chat-status {
			margin-top: -16px;
		}

		.contacts {
			display: grid;
			grid-template-columns: 1fr 1fr;
			gap: 16px;
			border: 0;
			background: none;
		}

		.card {
			gap: 14px;
			padding: 22px 24px;
			border: 1px solid var(--color-border);
			border-radius: 20px;
			background: var(--color-surface);
		}

		.card + .card {
			border-top: 1px solid var(--color-border);
		}

		.head {
			margin-top: 0;
		}

		h2 {
			font-size: 17px;
			line-height: 22px;
		}

		.sub {
			font-size: 14px;
		}
	}

	/* Fine pointers get E11's compact rows; touch keeps 44 px targets. */
	@media (min-width: 1024px) and (pointer: fine) {
		.row,
		dd a {
			min-height: 28px;
		}
	}
</style>
