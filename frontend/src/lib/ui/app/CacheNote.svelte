<!--
	Blueprint 20 B6: the quiet label over cached data (decision 36a wording).
	"Updating…" while the fresh read is on its way; "Last updated HH:MM ·
	offline" offline, or without the suffix when the refresh failed.
-->
<script lang="ts">
	import { staleLabel } from '#lib/client/device-cache.js';

	let {
		savedAt,
		online,
		failed = false
	}: { savedAt: number | null; online: boolean; failed?: boolean } = $props();
</script>

{#if savedAt !== null}
	<p class="cache-note" role="status" data-testid="cache-note">
		{online && !failed ? 'Updating…' : staleLabel(savedAt, !online)}
	</p>
{/if}

<style>
	.cache-note {
		margin: 0 0 var(--spacing-2);
		font-size: var(--text-12);
		line-height: var(--leading-16);
		color: var(--color-muted);
	}
</style>
