<!-- Notifications (mobile pushed page), Paper "App — Screens v3" H07. The list waits on U-11. -->
<script lang="ts">
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import RootImage from '#lib/ui/RootImage.svelte';
</script>

<svelte:head><title>Notifications · Elivate Wallet</title></svelte:head>

<header class="navbar">
	<a class="back" href="/app" aria-label="Back to Home"
		><ChevronLeft size={22} strokeWidth={2} aria-hidden="true" /></a
	>
	<h1>Notifications</h1>
	<span class="spacer" aria-hidden="true"></span>
</header>

<section class="empty">
	<RootImage pose="notifications" class="empty-root" sizes="210px" eager />
	<p class="title">No notifications yet</p>
	<p class="lead">Updates about your money show up here.</p>
</section>

<style>
	.navbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: calc(4px + env(safe-area-inset-top)) 16px 8px 12px;
	}

	.back,
	.spacer {
		display: flex;
		align-items: center;
		justify-content: center;
		width: var(--hit-min);
		height: var(--hit-min);
		color: var(--color-text);
	}

	h1 {
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.empty {
		display: flex;
		flex: 1;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 8px;
		padding: 0 32px 120px;
		text-align: center;
	}

	.empty :global(.empty-root) {
		width: 210px;
		height: 280px;
	}

	.title {
		padding-top: 12px;
		font-size: 22px;
		font-weight: var(--font-weight-bold);
		letter-spacing: -0.02em;
		line-height: 28px;
	}

	.lead {
		color: var(--color-muted);
		font-size: 15px;
		line-height: 22px;
	}

	@media (min-width: 1024px) {
		.navbar {
			display: none;
		}

		.empty {
			padding: 48px 32px;
		}
	}
</style>
