<!--
	Blueprint 23: the light page frame shown while a tapped page is still on its
	way (its code or its route data). The title comes from the shell's breadcrumb
	list; the blocks are placeholders only, never data.
-->
<script lang="ts">
	let { title }: { title: string } = $props();
	const heading = $derived(title.split('/').at(-1)?.trim() ?? '');
</script>

<div class="frame" data-testid="page-frame" aria-busy="true">
	<p class="visually-hidden" role="status">Opening {heading}</p>
	<div class="hero" aria-hidden="true">
		<span class="title">{heading}</span>
	</div>
	<div class="block" aria-hidden="true"></div>
	<div class="block short" aria-hidden="true"></div>
</div>

<style>
	.frame {
		display: flex;
		flex-direction: column;
		gap: 16px;
		min-width: 0;
	}

	.hero {
		display: flex;
		align-items: flex-end;
		min-height: 120px;
		padding: 20px;
		border-radius: 18px;
		background: var(--color-surface);
	}

	.title {
		color: var(--color-text);
		font-size: var(--text-24, 24px);
		font-weight: var(--font-weight-semibold);
		line-height: 1.2;
	}

	.block {
		height: 180px;
		border-radius: 18px;
		background: var(--color-surface);
		animation: pulse 1.2s ease-in-out infinite;
	}

	.block.short {
		height: 96px;
	}

	@keyframes pulse {
		50% {
			opacity: 0.6;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.block {
			animation: none;
		}
	}
</style>
