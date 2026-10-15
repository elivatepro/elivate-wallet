<!--
	Blueprint 23: the light page frame shown while a tapped page is still on its
	way (its code or its route data). The title comes from the shell's breadcrumb
	list; the blocks are placeholders only, never data.
	Blueprint 41: content-shaped outlines (a heading, a card, a few list rows)
	with a soft sweep (.ew-skel in base.css; still under reduced motion). Also
	the admin console's frame while one of its pages loads.
-->
<script lang="ts">
	let { title = '', rows = 4 }: { title?: string; rows?: number } = $props();
	const heading = $derived(title.split('/').at(-1)?.trim() ?? '');
</script>

<div class="frame" data-testid="page-frame" aria-busy="true">
	<p class="visually-hidden" role="status">{heading ? `Opening ${heading}` : 'Opening'}</p>
	<div class="head" aria-hidden="true">
		{#if heading}<span class="title">{heading}</span>{:else}<span class="ew-skel heading"
			></span>{/if}
		<span class="ew-skel line short"></span>
	</div>
	<div class="card" aria-hidden="true">
		<span class="ew-skel line tiny"></span>
		<span class="ew-skel figure"></span>
		<span class="chips">
			<span class="ew-skel chip"></span>
			<span class="ew-skel chip"></span>
		</span>
	</div>
	<ul class="list" aria-hidden="true">
		{#each { length: rows }, i (i)}
			<li class="row">
				<span class="ew-skel dot"></span>
				<span class="text">
					<span class="ew-skel line" style:width="{56 - (i % 3) * 10}%"></span>
					<span class="ew-skel line tiny"></span>
				</span>
				<span class="ew-skel line amount"></span>
			</li>
		{/each}
	</ul>
</div>

<style>
	.frame {
		display: flex;
		flex-direction: column;
		gap: 16px;
		min-width: 0;
	}

	.head {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 4px 0 4px;
	}

	.title {
		color: var(--color-text);
		font-size: var(--text-24, 24px);
		font-weight: var(--font-weight-semibold);
		line-height: 1.2;
	}

	.heading {
		width: 46%;
		height: 28px;
		border-radius: var(--radius-8, 8px);
	}

	.line {
		display: block;
		height: 12px;
		border-radius: var(--radius-pill);
	}

	.line.short {
		width: 38%;
	}

	.line.tiny {
		width: 28%;
		height: 10px;
	}

	.card {
		display: flex;
		flex-direction: column;
		gap: 14px;
		padding: 20px;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 22px;
		background: var(--color-surface);
	}

	.figure {
		width: 62%;
		height: 34px;
		border-radius: var(--radius-8, 8px);
	}

	.chips {
		display: flex;
		gap: 10px;
		padding-top: 6px;
	}

	.chip {
		width: 96px;
		height: 36px;
		border-radius: var(--radius-pill);
	}

	.list {
		display: flex;
		flex-direction: column;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: var(--radius-16);
		background: var(--color-surface);
	}

	.row {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 14px 18px;
	}

	.row + .row {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.dot {
		flex-shrink: 0;
		width: 36px;
		height: 36px;
		border-radius: var(--radius-pill);
	}

	.text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 8px;
		min-width: 0;
	}

	.amount {
		flex-shrink: 0;
		width: 72px;
	}

	@media (min-width: 1024px) {
		.card {
			min-height: 180px;
			padding: 28px;
			border-radius: var(--radius-24, 24px);
		}
	}
</style>
