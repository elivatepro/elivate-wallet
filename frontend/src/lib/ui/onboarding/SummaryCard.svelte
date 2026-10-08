<!-- Label/value rows in a quiet card (Paper Welcome "Membership card", All set summary). -->
<script lang="ts">
	import type { Snippet } from 'svelte';

	let { rows }: { rows: ReadonlyArray<{ label: string; value?: string; badge?: Snippet }> } =
		$props();
</script>

<dl class="card">
	{#each rows as row (row.label)}
		<div class="row">
			<dt>{row.label}</dt>
			<dd>
				{#if row.badge}{@render row.badge()}{:else}{row.value}{/if}
			</dd>
		</div>
	{/each}
</dl>

<style>
	.card {
		display: flex;
		flex-direction: column;
		margin: 0;
		border-radius: var(--radius-16);
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		background: color-mix(in oklab, var(--color-surface) 80%, transparent);
	}

	.row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 14px 16px;
	}

	.row + .row {
		border-top: 1px solid color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	dt {
		color: var(--color-muted);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	dd {
		margin: 0;
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
		text-align: right;
		overflow-wrap: anywhere;
	}
</style>
