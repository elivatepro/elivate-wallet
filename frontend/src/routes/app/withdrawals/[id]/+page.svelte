<!--
	One of my withdrawals (Blueprint 44 D4), Paper WF01: the full page on
	phones and narrow windows. From 1280 px the same link opens the list with
	the side panel (WF04, /app/withdrawals?w=<id>), so a deep link works on both.
-->
<script lang="ts">
	import { afterNavigate, goto } from '$app/navigation';
	import { page } from '$app/state';
	import { MediaQuery } from 'svelte/reactivity';
	import WithdrawalDetail from '#lib/ui/money/WithdrawalDetail.svelte';

	const wide = new MediaQuery('(min-width: 1280px)');
	const id = $derived(page.params.id ?? '');

	$effect(() => {
		if (wide.current && id) {
			void goto(`/app/withdrawals?w=${encodeURIComponent(id)}`, { replaceState: true });
		}
	});

	// Opened from a tap inside the app (or reached with Back/Forward): back goes
	// where it was. A deep link (push, email) or a redirect from the desktop
	// link (?w=, which replaced its own entry) goes to the list.
	let fromApp = false;
	afterNavigate((nav) => {
		fromApp = !!nav.from && (nav.type === 'link' || nav.type === 'popstate');
	});
	function close() {
		if (fromApp) history.back();
		else void goto('/app/withdrawals');
	}
</script>

<svelte:head><title>Withdrawal · Elivate Wallet</title></svelte:head>

{#if !wide.current && id}
	{#key id}
		<WithdrawalDetail {id} variant="page" onClose={close} />
	{/key}
{/if}
