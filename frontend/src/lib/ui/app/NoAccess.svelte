<!--
	No access, Paper "App — Screens v2" X03 (desktop) / X04 (mobile): Root at
	the velvet rope, "You don’t have access" and the way back. Leaders go back
	to Team overview (X03), everyone else to Home. Shown when the backend
	answers `authorization_denied` for a whole page; it decides nothing itself.
-->
<script lang="ts">
	import { getContext } from 'svelte';
	import { page } from '$app/state';
	import type { Shell } from '#lib/client/shell.svelte.js';
	import StateScreen from './StateScreen.svelte';

	let {
		title = 'You don’t have access',
		lead = 'Your role doesn’t include this page. Ask your President if you need it.',
		headingLevel = 1
	}: {
		title?: string;
		lead?: string;
		/** 2 under a page that already has its own h1 (pushed entry pages). */
		headingLevel?: 1 | 2;
	} = $props();

	const shell = getContext<Shell | undefined>('shell');
	const can = (permission: string) =>
		shell?.state.kind === 'ready' &&
		(shell.state.view.capabilities?.permissions ?? []).includes(permission);
	/** Same leadership hint as the shell's Team overview (Home since Slice 28). */
	const team = $derived(
		(can('view_managed_wallets') || can('view_scoped_financial_reports')) &&
			page.url.pathname !== '/app'
	);

	const switchWorkspace = () => window.location.assign('/workspaces?switch');
</script>

<StateScreen pose="no-access" eyebrow="No access" {title} {lead} {headingLevel} wide>
	{#snippet actions()}
		{#if team}
			<a class="state-primary" href="/app"
				><span class="desktop-only">Back to Team overview</span><span class="mobile-only"
					>Back to Overview</span
				></a
			>
		{:else}
			<a class="state-primary" href="/app">Go to Home</a>
		{/if}
		<button type="button" class="state-ghost" onclick={switchWorkspace}>Switch workspace</button>
	{/snippet}
</StateScreen>

<style>
	.desktop-only {
		display: none;
	}

	@media (min-width: 1024px) {
		.desktop-only {
			display: inline;
		}

		.mobile-only {
			display: none;
		}
	}
</style>
