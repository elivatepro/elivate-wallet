<script lang="ts">
	import { page } from '$app/state';
	import AuthLayout from '#lib/ui/auth/AuthLayout.svelte';
	import type { LayoutProps } from './$types';

	let { data, children }: LayoutProps = $props();
</script>

<svelte:head>
	<!-- Slice 33: one address per public page (no query strings or tokens). -->
	<link rel="canonical" href={`https://app.elivatewallet.com${page.url.pathname}`} />
</svelte:head>

<AuthLayout theme={data.theme}>
	{@render children()}
</AuthLayout>
