<!-- Mobile "More" tab: the sections that aren't in the bottom tabs, and sign out. -->
<script lang="ts">
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import LogOut from '@lucide/svelte/icons/log-out';

	const sections = [
		{ href: '/admin/applications', label: 'Founder applications' },
		{ href: '/admin/accounts', label: 'Accounts' },
		{ href: '/admin/nin', label: 'NIN reviews' },
		{ href: '/admin/switches', label: 'Kill switches' },
		{ href: '/admin/audit', label: 'Audit' },
		{ href: '/admin/backups', label: 'Backups & restores' },
		{ href: '/admin/emails', label: 'Failed emails' },
		{ href: '/admin/admins', label: 'Admins' }
	];
</script>

<div class="admin-page">
	<nav class="admin-card" aria-label="More sections">
		<ul>
			{#each sections as s (s.href)}
				<li><a href={s.href}>{s.label}<ChevronRight size={16} aria-hidden="true" /></a></li>
			{/each}
		</ul>
	</nav>
	<form class="admin-card" method="POST" action="/admin/sign-out">
		<button type="submit"><LogOut size={16} aria-hidden="true" />Sign out</button>
	</form>
</div>

<style>
	ul {
		margin: 0;
		padding: 0;
		list-style: none;
	}
	li + li {
		border-top: 1px solid color-mix(in oklab, var(--color-border) 30%, transparent);
	}
	a,
	button {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		width: 100%;
		min-height: 56px;
		padding: 0 20px;
		border: 0;
		background: transparent;
		font: inherit;
		font-size: 15px;
		color: var(--color-text);
		text-decoration: none;
		cursor: pointer;
	}
	button {
		justify-content: flex-start;
		color: var(--color-danger);
	}
	a :global(svg) {
		color: var(--color-muted);
	}
</style>
