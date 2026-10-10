<!--
	Root error page, rendered without the app shell (unknown top-level paths,
	auth pages, server errors). 404: Paper "App — Screens v2" X01/X02 copy and
	Root (upside-down map). Anything else: the load-error Root, "Something went
	wrong" and the message or reference when there is one. Unknown /app/* paths
	render app/+error.svelte inside the shell instead.
-->
<script lang="ts">
	import { page } from '$app/state';
	import StateScreen from '#lib/ui/app/StateScreen.svelte';

	const missing = $derived(page.status === 404);
	const reference = $derived.by(() => {
		const err: unknown = page.error;
		return err && typeof err === 'object' && 'reference' in err && typeof err.reference === 'string'
			? err.reference
			: null;
	});
</script>

<svelte:head
	><title>{missing ? 'Not found' : 'Something went wrong'} · Elivate Wallet</title></svelte:head
>

<main class="page" id="main">
	{#if missing}
		<StateScreen
			pose="not-found"
			eyebrow="Error 404"
			title="This page isn’t on the map"
			lead="The link may be old or mistyped. Let’s get you back."
		>
			{#snippet actions()}
				<a class="state-primary" href="/app">Go to Home</a>
				<a class="state-ghost" href="/app/support">Contact support</a>
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
</main>

<style>
	.page {
		display: flex;
		flex-direction: column;
		justify-content: center;
		min-height: 100dvh;
		padding: calc(8px + env(safe-area-inset-top)) 20px calc(32px + env(safe-area-inset-bottom));
	}

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

	@media (min-width: 1024px) {
		.page {
			padding: 32px 40px 40px;
		}
	}
</style>
