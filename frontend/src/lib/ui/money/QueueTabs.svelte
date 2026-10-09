<!--
	Queue tabs (Paper v1 T03, C09; v2 W05): 42 px tabs with a coral underline;
	the first tab's count is a coral badge while it has items.
-->
<script lang="ts" generics="K extends string">
	let {
		tabs,
		value = $bindable(),
		label
	}: {
		tabs: ReadonlyArray<{ key: K; label: string; count?: number; hot?: boolean }>;
		value: K;
		label: string;
	} = $props();
</script>

<div class="mm-tabs" role="tablist" aria-label={label}>
	{#each tabs as t (t.key)}
		<button
			type="button"
			role="tab"
			class="mm-tab"
			aria-selected={value === t.key}
			onclick={() => (value = t.key)}
		>
			{t.label}
			{#if t.count}<span class="mm-count" class:hot={t.hot}>{t.count}</span>{/if}
		</button>
	{/each}
</div>
