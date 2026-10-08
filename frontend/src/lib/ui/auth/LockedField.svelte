<!--
	Read-only value the person cannot change (Authentication v2 08/09: the email
	an invitation is bound to). Dashed outline, wraps long addresses (09b).
	Not a form control: the server derives the value itself (W-02 step 3).
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import Lock from '@lucide/svelte/icons/lock';

	let {
		id,
		label,
		value,
		locked = true,
		trailing
	}: {
		id: string;
		label: string;
		value: string;
		/** Shows the lock glyph inside the box. */
		locked?: boolean;
		/** Right side of the label row (e.g. the Verified badge). */
		trailing?: Snippet;
	} = $props();
</script>

<div class="field">
	<div class="label-row">
		<span class="label" id={`${id}-label`}>{label}</span>
		{#if trailing}{@render trailing()}{/if}
	</div>
	<div class="value" role="group" aria-labelledby={`${id}-label`}>
		<span class="text">{value}</span>
		{#if locked}
			<span class="lock" aria-hidden="true"><Lock size={18} strokeWidth={1.6} /></span>
		{/if}
	</div>
</div>

<style>
	.field {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.label-row {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
	}

	.label {
		color: var(--auth-label);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	.value {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: 12px;
		min-height: 52px;
		padding: 14px 16px;
		border-radius: var(--radius-12);
		border: 1px dashed color-mix(in oklab, var(--color-text) 16%, transparent);
		background: color-mix(in oklab, var(--color-text) 4%, transparent);
	}

	.text {
		flex: 1;
		min-width: 0;
		color: var(--color-text);
		font-size: 15px;
		line-height: var(--leading-24);
		overflow-wrap: anywhere;
	}

	.lock {
		display: flex;
		align-items: center;
		flex-shrink: 0;
		height: 24px;
		color: var(--color-muted);
	}
</style>
