<script lang="ts">
	import '#lib/ui/admin/admin.css';
	import { page } from '$app/state';
	import AdminShell from '#lib/ui/admin/AdminShell.svelte';
	import type { LayoutProps } from './$types';

	let { data, children }: LayoutProps = $props();
	const title = $derived(typeof page.data.title === 'string' ? page.data.title : 'Admin');
</script>

<svelte:head><title>{title} · Elivate Admin</title></svelte:head>

<AdminShell
	path={page.url.pathname}
	{title}
	name={data.me.name}
	uid={data.me.uid}
	stepUpUntil={data.stepUpUntil}
>
	{@render children()}
</AdminShell>
