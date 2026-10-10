<!--
	Labelled text/email/password field (Authentication v2: 52 px, 12 px radius).
	The password visibility toggle appears only after hydration; before that the
	field is a plain password input. The typed text lives in local state bound to
	the input, so re-renders (the show/hide toggle, an error appearing) never write
	the `value` prop back over what the person typed; a new `value` from the parent
	(a form echo) still replaces it.
-->
<script lang="ts">
	import type { Snippet } from 'svelte';
	import { onMount } from 'svelte';
	import Eye from '@lucide/svelte/icons/eye';
	import EyeOff from '@lucide/svelte/icons/eye-off';

	let {
		id,
		name,
		label,
		type = 'text',
		value = '',
		placeholder,
		autocomplete,
		error,
		hint,
		required = true,
		minlength,
		maxlength,
		trailing
	}: {
		id: string;
		name: string;
		label: string;
		type?: 'text' | 'email' | 'password';
		value?: string;
		placeholder?: string;
		autocomplete?: HTMLInputElement['autocomplete'];
		error?: string | null;
		hint?: string;
		required?: boolean;
		minlength?: number;
		maxlength?: number;
		trailing?: Snippet;
	} = $props();

	let mounted = $state(false);
	let revealed = $state(false);
	onMount(() => (mounted = true));

	// Typing overrides it; it follows the prop only when the prop itself changes.
	let current = $derived(value);

	const inputType = $derived(type === 'password' && revealed ? 'text' : type);
	const describedBy = $derived(
		[error ? `${id}-error` : null, hint ? `${id}-hint` : null].filter(Boolean).join(' ') ||
			undefined
	);
</script>

<div class="field">
	<div class="label-row">
		<label for={id}>{label}</label>
		{#if trailing}{@render trailing()}{/if}
	</div>
	<div class="control" class:invalid={!!error}>
		<input
			{id}
			{name}
			type={inputType}
			bind:value={current}
			{placeholder}
			{autocomplete}
			{required}
			{minlength}
			{maxlength}
			autocapitalize="off"
			spellcheck="false"
			aria-invalid={error ? 'true' : undefined}
			aria-describedby={describedBy}
		/>
		{#if type === 'password' && mounted}
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
	{#if hint}<p class="hint" id={`${id}-hint`}>{hint}</p>{/if}
	{#if error}<p class="error" id={`${id}-error`}>{error}</p>{/if}
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

	label {
		color: var(--auth-label);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
	}

	.control {
		display: flex;
		align-items: center;
		height: 52px;
		padding-left: 16px;
		padding-right: 6px;
		border-radius: var(--radius-12);
		border: 1px solid var(--auth-field-border);
		background: var(--auth-field-bg);
	}

	.control:focus-within {
		border-color: var(--color-accent);
		box-shadow: color-mix(in oklab, var(--color-accent) 20%, transparent) 0px 0px 0px 3px;
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
		font-size: 15px;
		line-height: var(--leading-20);
		outline: none;
	}

	input::placeholder {
		color: var(--auth-placeholder);
		opacity: 1;
	}

	.reveal {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: var(--hit-min);
		height: var(--hit-min);
		border: 0;
		border-radius: var(--radius-8);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}

	.hint {
		color: var(--auth-body);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	.error {
		color: var(--color-danger);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}
</style>
