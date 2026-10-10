<!--
	Errors inside the signed-in shell. 404 (unknown /app/* paths, via the
	[...missing] catch-all): Paper "App — Screens v2" X01 (desktop) / X02
	(mobile), Root with the upside-down map. Anything else: the load-error Root,
	"Something went wrong" and the message or reference when there is one.
-->
<script lang="ts">
	import { page } from '$app/state';
	import Search from '@lucide/svelte/icons/search';
	import StateScreen from '#lib/ui/app/StateScreen.svelte';

	const missing = $derived(page.status === 404);
	const reference = $derived.by(() => {
		const err: unknown = page.error;
		return err && typeof err === 'object' && 'reference' in err && typeof err.reference === 'string'
			? err.reference
			: null;
	});

	/** Opens quick search (K01/K02) through its ⌘K / Ctrl+K shortcut. */
	function searchWallet() {
		window.dispatchEvent(
			new KeyboardEvent('keydown', { key: 'k', metaKey: true, ctrlKey: true, bubbles: true })
		);
	}
</script>

<svelte:head
	><title>{missing ? 'Not found' : 'Something went wrong'} · Elivate Wallet</title></svelte:head
>

{#if missing}
	<StateScreen
		pose="not-found"
		eyebrow="Error 404"
		title="This page isn’t on the map"
		lead="The link may be old or mistyped. Let’s get you back."
	>
		{#snippet actions()}
			<a class="state-primary" href="/app">Go to Home</a>
			<button type="button" class="state-ghost" onclick={searchWallet}>
				<Search class="state-icon" size={16} strokeWidth={2} aria-hidden="true" />
				Search Wallet
				<kbd class="state-key" aria-hidden="true">⌘K</kbd>
			</button>
		{/snippet}
	</StateScreen>
{:else}
	<StateScreen
		pose="load-error"
		eyebrow={`Error ${page.status}`}
		title="Something went wrong"
		lead={page.error?.message ?? 'Something went wrong. Try again.'}
	>
		{#if reference}
			<p class="reference"><span>Reference</span><span class="code">{reference}</span></p>
		{/if}
		{#snippet actions()}
			<a class="state-primary" href="/app">Go to Home</a>
			<a class="state-ghost" href="/app/support">Contact support</a>
		{/snippet}
	</StateScreen>
{/if}

<style>
	.reference {
		display: flex;
		gap: 8px;
		color: var(--color-muted);
		font-size: 13px;
		line-height: 18px;
	}

	.code {
		color: var(--color-text);
		font-family: var(--font-mono);
	}
</style>
