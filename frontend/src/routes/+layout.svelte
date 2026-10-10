<script lang="ts">
	import { onMount } from 'svelte';
	import '@fontsource-variable/lexend/wght.css';
	import '@fontsource/ibm-plex-mono/latin-400.css';
	import '#lib/ui/base.css';
	// Blueprint 20 B8: the same hashed file the @font-face above uses, preloaded.
	import lexendLatin from '@fontsource-variable/lexend/files/lexend-latin-wght-normal.woff2?url';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();

	// Blueprint 20 B8: the Wallet registers the service worker (Kit's own
	// registration is off). The Admin site never does, and drops one an older
	// build left on its own host.
	onMount(() => {
		if (!('serviceWorker' in navigator)) return;
		const path = location.pathname;
		if (path === '/admin' || path.startsWith('/admin/')) {
			if (location.hostname.startsWith('admin.')) {
				void navigator.serviceWorker
					.getRegistrations()
					.then((all) => all.forEach((r) => void r.unregister()));
			}
			return;
		}
		const register = () =>
			void navigator.serviceWorker
				.register('/service-worker.js', { type: 'module' })
				.catch(() => undefined);
		if (document.readyState === 'complete') register();
		else addEventListener('load', register, { once: true });
	});
</script>

<svelte:head>
	<title>Elivate Wallet</title>
	<link rel="preload" as="font" type="font/woff2" href={lexendLatin} crossorigin="anonymous" />
</svelte:head>

{@render children()}
