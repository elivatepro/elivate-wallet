<!-- Status pill, Paper "Admin — Screens v1": 12 px text on a soft fill of its tone. -->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { Tone } from '#lib/admin.js';

	let { tone = 'neutral', children }: { tone?: Tone; children: Snippet } = $props();
</script>

<span class="badge {tone}">{@render children()}</span>

<style>
	.badge {
		display: inline-flex;
		align-items: center;
		padding: 3px 9px;
		border-radius: 999px;
		font-size: 12px;
		font-weight: 500;
		line-height: 16px;
		white-space: nowrap;
	}
	.success {
		background: color-mix(in oklab, var(--color-success) 16%, var(--color-surface));
		color: var(--color-success);
	}
	.warning {
		background: color-mix(in oklab, var(--color-warning) 16%, var(--color-surface));
		color: var(--color-warning);
	}
	.danger {
		background: color-mix(in oklab, var(--color-danger) 16%, var(--color-surface));
		color: var(--color-danger);
	}
	.info {
		background: color-mix(in oklab, var(--color-info) 16%, var(--color-surface));
		color: var(--color-info);
	}
	.accent {
		background: var(--color-accent-subtle);
		color: var(--color-accent-text);
	}
	.neutral {
		background: var(--color-raised);
		color: var(--color-muted);
	}
</style>
