<script lang="ts">
	import '#lib/ui/admin/admin.css';
	import { navigating, page } from '$app/state';
	import AdminShell from '#lib/ui/admin/AdminShell.svelte';
	import PageFrame from '#lib/ui/app/PageFrame.svelte';
	import type { LayoutProps } from './$types';

	let { data, children }: LayoutProps = $props();
	const title = $derived(typeof page.data.title === 'string' ? page.data.title : 'Admin');

	/**
	 * Blueprint 41: a console page still loading after 150 ms (each is a gated
	 * server round trip) shows its outline instead of the old page; the tapped
	 * link spins too (root layout).
	 */
	let slowNav = $state(false);
	$effect(() => {
		const to = navigating.to?.url.pathname;
		if (!to || to === page.url.pathname || !to.startsWith('/admin') || navigating.type === 'form')
			return;
		const timer = setTimeout(() => (slowNav = true), 150);
		return () => {
			clearTimeout(timer);
			slowNav = false;
		};
	});
</script>

<svelte:head><title>{title} · Elivate Admin</title></svelte:head>

<AdminShell
	path={page.url.pathname}
	{title}
	name={data.me.name}
	uid={data.me.uid}
	stepUpUntil={data.stepUpUntil}
>
	{#if slowNav}
		<PageFrame rows={5} />
	{:else}
		{@render children()}
	{/if}
</AdminShell>
