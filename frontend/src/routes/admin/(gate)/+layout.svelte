<script lang="ts">
	import AuthLayout from '#lib/ui/auth/AuthLayout.svelte';
	import type { LayoutProps } from './$types';

	let { data, children }: LayoutProps = $props();
</script>

<AuthLayout theme={data.theme} brandHref="/admin" brandName="Elivate Admin" platform>
	{@render children()}
</AuthLayout>
