<!-- "New to Elivate? Start your network" row (Authentication v2). -->
<script lang="ts">
	let { prompt, label, href }: { prompt?: string; label: string; href: string } = $props();
</script>

<p class="alt">
	{#if prompt}<span class="prompt">{prompt}</span>{/if}
	<a {href}>{label}</a>
</p>

<style>
	.alt {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: center;
		gap: 6px;
		min-height: var(--hit-min);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.prompt {
		color: var(--color-muted);
	}

	a {
		display: inline-flex;
		align-items: center;
		min-height: var(--hit-min);
		color: var(--color-text);
		font-weight: var(--font-weight-medium);
		text-decoration: underline 1px var(--auth-link-underline);
		text-underline-offset: 4px;
	}
</style>
