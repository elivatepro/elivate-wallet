<!--
	Wizard progress (Paper "Onboarding — Invited member" panel header): optional
	back chip, four 4 px bars (coral done, green when all set) and "n / 4".
-->
<script lang="ts">
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';

	let {
		step,
		total = 4,
		complete = false,
		backHref
	}: { step: number; total?: number; complete?: boolean; backHref?: string } = $props();
</script>

<div class="progress" class:complete>
	{#if backHref}
		<a class="back" href={backHref} aria-label="Back"><ChevronLeft size={20} strokeWidth={2} /></a>
	{/if}
	<div
		class="bars"
		role="progressbar"
		aria-label="Setup progress"
		aria-valuemin={0}
		aria-valuemax={total}
		aria-valuenow={step}
	>
		{#each Array.from({ length: total }, (_unused, i) => i) as i (i)}
			<span class="bar" class:on={i < step}></span>
		{/each}
	</div>
	<span class="count" aria-hidden="true">{step} / {total}</span>
</div>

<style>
	.progress {
		display: flex;
		align-items: center;
		gap: 14px;
	}

	.back {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: var(--hit-min);
		height: var(--hit-min);
		margin: -12px 0 -12px -12px;
		border-radius: var(--radius-pill);
		color: var(--color-text);
	}

	.bars {
		display: flex;
		flex: 1;
		gap: 6px;
	}

	.bar {
		flex: 1;
		height: 4px;
		border-radius: var(--radius-pill);
		background: color-mix(in oklab, var(--color-text) 16%, transparent);
	}

	.bar.on {
		background: var(--color-accent);
	}

	.complete .bar.on {
		background: var(--color-success);
	}

	.count {
		flex-shrink: 0;
		color: var(--auth-body);
		font-family: var(--font-mono);
		font-size: var(--text-12);
		letter-spacing: 0.08em;
		line-height: var(--leading-16);
	}
</style>
