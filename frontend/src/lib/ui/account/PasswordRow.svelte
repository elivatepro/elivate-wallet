<!--
	The new-password row of Change password, Paper "App — Screens v4" Z08
	(desktop: label left, a 300 px field right, like the PIN rows of S05;
	mobile: label above, full width). The Z03 field with its show/hide toggle,
	which appears only after hydration. The value is never echoed back after a
	failed try (the page remounts the row).
-->
<script lang="ts">
	import { onMount } from 'svelte';
	import Eye from '@lucide/svelte/icons/eye';
	import EyeOff from '@lucide/svelte/icons/eye-off';

	let {
		id,
		name,
		label,
		placeholder,
		minlength,
		maxlength,
		error = null,
		autofocus = false
	}: {
		id: string;
		name: string;
		label: string;
		placeholder: string;
		minlength: number;
		maxlength: number;
		error?: string | null;
		autofocus?: boolean;
	} = $props();

	let mounted = $state(false);
	let revealed = $state(false);
	let input: HTMLInputElement | undefined = $state();

	onMount(() => {
		mounted = true;
		if (autofocus) input?.focus();
	});
</script>

<div class="row">
	<label for={id}>{label}</label>
	<div class="control" class:invalid={!!error}>
		<input
			bind:this={input}
			{id}
			{name}
			type={revealed ? 'text' : 'password'}
			{placeholder}
			{minlength}
			{maxlength}
			required
			autocomplete="new-password"
			autocapitalize="off"
			spellcheck="false"
			aria-invalid={error ? 'true' : undefined}
			aria-describedby={error ? `${id}-error` : undefined}
		/>
		{#if mounted}
			<button
				type="button"
				class="reveal"
				aria-label={revealed ? 'Hide password' : 'Show password'}
				aria-pressed={revealed}
				aria-controls={id}
				onclick={() => (revealed = !revealed)}
			>
				{#if revealed}
					<EyeOff size={20} strokeWidth={1.6} aria-hidden="true" />
				{:else}
					<Eye size={20} strokeWidth={1.6} aria-hidden="true" />
				{/if}
			</button>
		{/if}
	</div>
	{#if error}<p class="error" id={`${id}-error`}>{error}</p>{/if}
</div>

<style>
	.row {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	label {
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.control {
		display: flex;
		align-items: center;
		height: 52px;
		padding-left: 16px;
		padding-right: 6px;
		border: 1px solid #2a2f31;
		border-radius: var(--radius-12);
		background: #141718;
	}

	:global([data-theme='light']) .control {
		border-color: var(--color-border);
		background: var(--color-raised);
	}

	.control:focus-within {
		border-color: var(--color-accent);
		box-shadow: #ff7f4f33 0px 0px 0px 3px;
	}

	.control.invalid {
		border-color: var(--color-danger);
	}

	input {
		flex: 1;
		min-width: 0;
		height: 100%;
		padding: 0;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font: inherit;
		font-size: 15px;
		line-height: var(--leading-20);
		outline: none;
	}

	input::placeholder {
		color: var(--color-muted);
		opacity: 1;
	}

	.reveal {
		display: flex;
		flex-shrink: 0;
		align-items: center;
		justify-content: center;
		width: var(--hit-min);
		height: var(--hit-min);
		border: 0;
		border-radius: var(--radius-8);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}

	.error {
		color: var(--color-danger);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	@media (min-width: 1024px) {
		.row {
			display: grid;
			grid-template-columns: 1fr auto;
			align-items: center;
			column-gap: 24px;
			row-gap: 8px;
		}

		label {
			font-size: 15px;
			line-height: 20px;
		}

		.control {
			width: 300px;
		}

		.error {
			grid-column: 1 / -1;
			justify-self: end;
		}
	}
</style>
