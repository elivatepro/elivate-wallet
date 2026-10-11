<!--
	4-digit PIN (Authentication v2 "Enter your PIN": four 56 px cells, active cell
	coral). One real input, announced as one control; the cells are decoration.
	Before hydration the input itself is visible, so the form works without JS.
	The PIN is never echoed back after a failed submit.
-->
<script lang="ts">
	import { onMount } from 'svelte';

	let {
		id,
		name,
		label,
		error,
		autocomplete = 'off',
		autofocus = false
	}: {
		id: string;
		name: string;
		label: string;
		error?: string | null;
		autocomplete?: HTMLInputElement['autocomplete'];
		autofocus?: boolean;
	} = $props();

	let value = $state('');
	let focused = $state(false);
	let enhanced = $state(false);
	let input: HTMLInputElement | undefined = $state();

	onMount(() => {
		enhanced = true;
		if (autofocus) input?.focus();
	});

	const onInput = (event: Event) => {
		const target = event.currentTarget as HTMLInputElement;
		value = target.value.replace(/[^0-9]/g, '').slice(0, 4);
		target.value = value;
	};
</script>

<div class="field">
	<label for={id}>{label}</label>
	<div class="pin" class:enhanced class:invalid={!!error}>
		<input
			bind:this={input}
			{id}
			{name}
			type="password"
			data-enter-submits
			inputmode="numeric"
			pattern={'[0-9]{4}'}
			minlength="4"
			maxlength="4"
			required
			{autocomplete}
			aria-invalid={error ? 'true' : undefined}
			aria-describedby={error ? `${id}-error` : undefined}
			oninput={onInput}
			onfocus={() => (focused = true)}
			onblur={() => (focused = false)}
		/>
		{#if enhanced}
			<div class="cells" aria-hidden="true">
				{#each [0, 1, 2, 3] as index (index)}
					<div
						class="cell"
						class:active={focused &&
							(index === value.length || (index === 3 && value.length === 4))}
					>
						{#if index < value.length}
							<span class="dot">•</span>
						{:else if focused && index === value.length}
							<span class="caret"></span>
						{/if}
					</div>
				{/each}
			</div>
		{/if}
	</div>
	{#if error}<p class="error" id={`${id}-error`}>{error}</p>{/if}
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

	.pin {
		position: relative;
	}

	input {
		width: 100%;
		height: 56px;
		padding: 0 16px;
		border-radius: var(--radius-12);
		border: 1px solid var(--auth-field-border);
		background: var(--auth-field-bg);
		color: var(--color-text);
		font-size: 24px;
		letter-spacing: 0.5em;
		outline: none;
	}

	.pin:not(.enhanced) input:focus {
		border-color: var(--color-accent);
	}

	.enhanced input {
		position: absolute;
		inset: 0;
		height: 56px;
		opacity: 0;
		cursor: text;
		z-index: 1;
	}

	.cells {
		display: flex;
		gap: 6px;
	}

	.cell {
		display: flex;
		flex: 1 1 0%;
		align-items: center;
		justify-content: center;
		height: 56px;
		border-radius: var(--radius-12);
		border: 1px solid var(--auth-field-border);
		background: var(--auth-field-bg);
	}

	.invalid .cell,
	.invalid input {
		border-color: var(--color-danger);
	}

	.cell.active {
		border-color: var(--color-accent);
		box-shadow: color-mix(in oklab, var(--color-accent) 20%, transparent) 0px 0px 0px 3px;
	}

	.dot {
		color: var(--color-text);
		font-size: 30px;
		font-weight: var(--font-weight-semibold);
		line-height: 30px;
	}

	.caret {
		width: 2px;
		height: 22px;
		background: var(--color-accent);
		animation: blink 1s steps(1) infinite;
	}

	@keyframes blink {
		50% {
			opacity: 0;
		}
	}

	.error {
		color: var(--color-danger);
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}
</style>
