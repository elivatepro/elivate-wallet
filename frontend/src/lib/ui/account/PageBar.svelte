<!-- Mobile nav bar of a pushed account page (Paper S04/S06/B10): back, centred title. -->
<script lang="ts">
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';

	let { title, back, backLabel }: { title: string; back: string; backLabel: string } = $props();
</script>

<header class="navbar">
	<a class="back" href={back} aria-label={backLabel}
		><ChevronLeft size={22} strokeWidth={2} aria-hidden="true" /></a
	>
	<p class="title">{title}</p>
	<span class="spacer" aria-hidden="true"></span>
</header>

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

	.title {
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	@media (min-width: 1024px) {
		.navbar {
			display: none;
		}
	}
</style>
