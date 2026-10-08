<!--
	11-digit NIN (Paper 04): mono digits grouped 3·4·4 while typing, lock note
	below. A plain text input before hydration; the server strips spaces.
-->
<script lang="ts">
	import { untrack } from 'svelte';
	import Lock from '@lucide/svelte/icons/lock';

	let {
		value = '',
		error,
		readonly = false,
		autofocus = false
	}: { value?: string; error?: string | null; readonly?: boolean; autofocus?: boolean } = $props();

	const group = (digits: string) =>
		[digits.slice(0, 3), digits.slice(3, 7), digits.slice(7, 11)].filter(Boolean).join(' ');

	// Seeded once from the server's echo; the person's typing owns it after that.
	let shown = $state(untrack(() => group(value.replace(/\D/g, ''))));
	const onInput = (event: Event) => {
		const target = event.currentTarget as HTMLInputElement;
		shown = group(target.value.replace(/\D/g, '').slice(0, 11));
		target.value = shown;
	};
</script>

<div class="field">
	<label for="nin">National Identification Number</label>
	<div class="control" class:invalid={!!error}>
		<!-- svelte-ignore a11y_autofocus -->
		<input
			id="nin"
			name="nin"
			type="text"
			inputmode="numeric"
			autocomplete="off"
			maxlength={13}
			value={shown}
			{readonly}
			{autofocus}
			oninput={onInput}
			aria-invalid={error ? 'true' : undefined}
			aria-describedby={error ? 'nin-error' : 'nin-hint'}
		/>
	</div>
	{#if error}
		<p class="error" id="nin-error">{error}</p>
	{:else}
		<p class="hint" id="nin-hint">
			<Lock size={14} strokeWidth={1.6} aria-hidden="true" />11 digits. Used only to verify your
			identity.
		</p>
	{/if}
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

	.control {
		display: flex;
		align-items: center;
		height: 56px;
		padding: 0 16px;
		border-radius: var(--radius-12);
		border: 1px solid var(--auth-field-border);
		background: var(--auth-field-bg);
	}

	.control:focus-within {
		border-color: var(--color-accent);
		box-shadow: color-mix(in oklab, var(--color-accent) 20%, transparent) 0 0 0 3px;
	}

	.control.invalid {
		border-color: var(--color-danger);
	}

	input {
		flex: 1;
		min-width: 0;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font-family: var(--font-mono);
		font-size: 20px;
		letter-spacing: 0.08em;
		outline: none;
	}

	.hint,
	.error {
		display: flex;
		align-items: center;
		gap: 6px;
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.hint {
		color: var(--auth-body);
	}

	.error {
		color: var(--color-danger);
	}
</style>
