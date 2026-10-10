<!--
	Admin command dialog, Paper A09b/A11b/A07b (reason + PIN). URL-driven: the
	page opens it with ?dialog=…, so it works before (and without) JavaScript;
	Cancel is a link back. Desktop: 520 px modal with the felt header and Root;
	mobile: bottom sheet. The PIN is never echoed back after a failure.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import { page } from '$app/state';
	import RootImage from '#lib/ui/RootImage.svelte';
	import PinField from '#lib/ui/auth/PinField.svelte';
	import type { RootPose } from '#lib/ui/root.svelte.js';

	let {
		pose,
		title,
		lead,
		action,
		cancelHref,
		submitLabel,
		tone = 'primary',
		idempotencyKey,
		error = null,
		reason = '',
		reasonLabel = 'Reason',
		reasonPlaceholder = '',
		children
	}: {
		pose: RootPose;
		title: string;
		lead?: string;
		/** Form action, e.g. "?/setSwitch". */
		action: string;
		cancelHref: string;
		submitLabel: string;
		tone?: 'primary' | 'danger';
		idempotencyKey: string;
		error?: string | null;
		reason?: string;
		reasonLabel?: string;
		reasonPlaceholder?: string;
		/** Extra fields above the reason (status choice, dates, hidden ids). */
		children?: Snippet;
	} = $props();

	// A bare "?/name" action keeps the page's query (?dialog=…) so a failed
	// submit re-renders this dialog with its error and the typed reason.
	const formAction = $derived.by(() => {
		if (!action.startsWith('?/')) return action;
		const kept = new URLSearchParams(
			[...page.url.searchParams].filter(([key]) => !key.startsWith('/'))
		).toString();
		return kept ? `?${kept}&${action.slice(1)}` : action;
	});
</script>

<div class="overlay">
	<a class="scrim" href={cancelHref} aria-label="Close" tabindex="-1"></a>
	<div class="dialog" role="dialog" aria-modal="true" aria-labelledby="admin-dialog-title">
		<header>
			<div class="shade" aria-hidden="true"></div>
			<div class="grain" aria-hidden="true"></div>
			<RootImage {pose} class="dialog-root" sizes="128px" eager />
			<div class="head-text">
				<h2 id="admin-dialog-title">{title}</h2>
				{#if lead}<p>{lead}</p>{/if}
			</div>
		</header>
		<form method="POST" action={formAction} novalidate>
			<input type="hidden" name="idempotencyKey" value={idempotencyKey} />
			{@render children?.()}
			<label class="reason">
				<span>{reasonLabel}</span>
				<textarea
					name="reason"
					required
					minlength="3"
					maxlength="500"
					rows="3"
					placeholder={reasonPlaceholder}
					value={reason}></textarea>
			</label>
			<PinField id="admin-pin" name="pin" label="Confirm it’s you · 4-digit PIN" />
			{#if error}<p class="error" role="alert">{error}</p>{/if}
			<div class="actions">
				<a class="btn" href={cancelHref}>Cancel</a>
				<button class="btn {tone}" type="submit">{submitLabel}</button>
			</div>
		</form>
	</div>
</div>

<style>
	.overlay {
		position: fixed;
		inset: 0;
		z-index: 50;
		display: flex;
		align-items: flex-start;
		justify-content: center;
		padding: 64px 16px;
		overflow-y: auto;
	}
	.scrim {
		position: fixed;
		inset: 0;
		background: color-mix(in oklab, #000 68%, transparent);
	}
	.dialog {
		position: relative;
		width: 520px;
		max-width: 100%;
		background: var(--color-surface);
		border: 1px solid color-mix(in oklab, var(--color-border) 70%, transparent);
		border-radius: 22px;
		overflow: clip;
		box-shadow: 0 30px 80px -30px #000c;
	}
	header {
		position: relative;
		display: flex;
		align-items: flex-end;
		height: 150px;
		padding: 0 28px 28px;
		background: #1a1d1e url('/auth-bg/mobile-dark.jpg') 50% 30% / cover;
		overflow: clip;
	}
	.shade,
	.grain {
		position: absolute;
		inset: 0;
	}
	.shade {
		background: linear-gradient(90deg, #1b1e1fec 0%, #1b1e1f99 55%, #1b1e1f00 100%);
	}
	.grain {
		background: url('/auth-bg/grain-256.png') repeat;
		mix-blend-mode: overlay;
		opacity: 0.25;
	}
	header :global(.dialog-root) {
		position: absolute;
		right: 24px;
		bottom: -12px;
		width: 128px;
		height: 168px;
	}
	.head-text {
		position: relative;
		max-width: 300px;
	}
	h2 {
		margin: 0;
		font-size: 24px;
		font-weight: 600;
		line-height: 30px;
		color: #f2f4f4;
	}
	.head-text p {
		margin: 4px 0 0;
		font-size: 14px;
		line-height: 20px;
		color: #c9cfd1;
	}
	form {
		display: flex;
		flex-direction: column;
		gap: 18px;
		padding: 24px 28px 28px;
	}
	.reason {
		display: flex;
		flex-direction: column;
		gap: 8px;
		font-size: 14px;
		font-weight: 500;
		color: var(--color-text);
	}
	textarea {
		resize: vertical;
		min-height: 88px;
		padding: 14px 16px;
		border-radius: 14px;
		border: 1px solid var(--color-border);
		background: var(--color-canvas);
		font: inherit;
		font-weight: 400;
		color: var(--color-text);
	}
	textarea:focus {
		outline: none;
		border-color: var(--color-accent);
	}
	.error {
		margin: 0;
		font-size: 14px;
		color: var(--color-danger);
	}
	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 12px;
	}
	.actions .btn {
		min-height: 48px;
		padding: 0 22px;
	}
	@media (max-width: 1023px) {
		.overlay {
			align-items: flex-end;
			padding: 0;
		}
		.dialog {
			width: 100%;
			border-radius: 28px 28px 0 0;
		}
		form {
			padding: 20px 20px 28px;
		}
		.actions .btn {
			flex: 1 1 0;
		}
	}
</style>
