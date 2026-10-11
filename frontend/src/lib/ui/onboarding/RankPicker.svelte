<!--
	Self-declared rank (W-02 step 5; Paper 09 field, 10 "Your rank" sheet).
	The shared wheel picker (Blueprint 24): a native <select> without JS; with
	JS a field that opens the "Your rank" wheel sheet with haptic detents and a
	search field (W-02: search, keyboard and empty-result support). Ranks show
	number first (Blueprint 21); the form posts the stored value. Rank is
	presentation only and grants nothing.
-->
<script lang="ts">
	import { RANKS } from '#lib/contract/identity.js';
	import { rankLabel } from '#lib/labels.js';
	import WheelPicker from '#lib/ui/WheelPicker.svelte';

	let { value = null, error }: { value?: string | null; error?: string | null } = $props();

	const options = RANKS.map((rank) => ({ value: rank, label: rankLabel(rank) }));
</script>

<div class="field">
	<label for="rank">Your rank</label>
	<WheelPicker
		id="rank"
		name="rank"
		variant="auth"
		label="Rank"
		title="Your rank"
		sub="Scroll to choose. You can change it later."
		confirmText="Set rank"
		placeholder="Select your rank"
		searchPlaceholder="Search ranks"
		initial="Executive Manager"
		{options}
		{value}
		invalid={!!error}
		describedby={error ? 'rank-error' : undefined}
	/>
	{#if error}<p class="error" id="rank-error">{error}</p>{/if}
</div>

<style>
	.field {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	label {
		color: var(--auth-label);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	.error {
		color: var(--color-danger);
		font-size: var(--text-14);
	}
</style>
