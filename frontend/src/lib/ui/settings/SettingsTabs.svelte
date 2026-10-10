<!--
	Settings tabs (Paper F01/F02/E09: Branding · Team details · Backup vault),
	underlined like the drawn screens. Branding and Team details need
	manage_team_settings; the vault also opens for request_restore (World Team).
-->
<script lang="ts">
	import { page } from '$app/state';

	let { canEdit, canVault }: { canEdit: boolean; canVault: boolean } = $props();

	const tabs = $derived(
		[
			canEdit ? { href: '/app/settings', label: 'Branding' } : null,
			canEdit ? { href: '/app/settings/details', label: 'Team details' } : null,
			canVault ? { href: '/app/settings/backups', label: 'Backup vault' } : null
		].filter((t): t is { href: string; label: string } => t !== null)
	);
	const current = $derived(
		page.url.pathname.startsWith('/app/settings/backups')
			? '/app/settings/backups'
			: page.url.pathname.startsWith('/app/settings/details')
				? '/app/settings/details'
				: '/app/settings'
	);
</script>

{#if tabs.length > 1}
	<nav class="s-tabs" aria-label="Settings">
		{#each tabs as tab (tab.href)}
			<a class="s-tab" href={tab.href} aria-current={current === tab.href ? 'page' : undefined}
				>{tab.label}</a
			>
		{/each}
	</nav>
{/if}

<style>
	.s-tabs {
		display: flex;
		gap: 4px;
		overflow-x: auto;
		border-bottom: 1px solid var(--color-border);
		scrollbar-width: none;
	}

	.s-tab {
		display: flex;
		align-items: center;
		min-height: 44px;
		padding: 0 14px;
		border-bottom: 2px solid transparent;
		color: var(--color-muted);
		font-size: 15px;
		line-height: 20px;
		text-decoration: none;
		white-space: nowrap;
	}

	.s-tab:hover {
		color: var(--color-text);
	}

	.s-tab[aria-current='page'] {
		border-bottom-color: var(--color-accent);
		color: var(--color-text);
		font-weight: var(--font-weight-semibold);
	}

	.s-tab:focus-visible {
		outline: 2px solid var(--focus-ring);
		outline-offset: -2px;
		border-radius: 8px;
	}
</style>
