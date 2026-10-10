<!--
	One PIN row of Change transaction PIN, Paper "App — Screens v2" S05
	(desktop: label left, four 52×56 cells right) / S06 (mobile: label above,
	cells share the width). One real input announced as one control; the cells
	are decoration. The value is never echoed back after a failed try (the
	page remounts the row).
-->
<script lang="ts">
	import { onMount } from 'svelte';

	let {
		id,
		name,
		label,
		error = null,
		autofocus = false
	}: {
		id: string;
		name: string;
		label: string;
		error?: string | null;
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

<div class="row">
	<label for={id}>{label}</label>
	<div class="pin" class:enhanced class:invalid={!!error}>
		<input
			bind:this={input}
			{id}
			{name}
			type="password"
			inputmode="numeric"
			pattern={'[0-9]{4}'}
			minlength="4"
			maxlength="4"
			required
			autocomplete="off"
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
							<span class="dot"></span>
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

	.pin {
		position: relative;
	}

	input {
		width: 100%;
		height: 56px;
		padding: 0 16px;
		border: 1px solid #2a2f31;
		border-radius: 14px;
		background: #141718;
		color: var(--color-text);
		font-size: 24px;
		letter-spacing: 0.5em;
		outline: none;
	}

	.enhanced input {
		position: absolute;
		inset: 0;
		opacity: 0;
		cursor: text;
		z-index: 1;
	}

	.cells {
		display: flex;
		gap: 10px;
	}

	.cell {
		display: flex;
		flex: 1 1 0%;
		align-items: center;
		justify-content: center;
		height: 56px;
		border: 1px solid #2a2f31;
		border-radius: 14px;
		background: #141718;
	}

	:global([data-theme='light']) .cell,
	:global([data-theme='light']) input {
		border-color: var(--color-border);
		background: var(--color-raised);
	}

	.invalid .cell,
	.invalid input {
		border-color: var(--color-danger);
	}

	.cell.active {
		border-color: var(--color-accent);
		box-shadow: var(--color-accent-ring) 0px 0px 0px 3px;
	}

	.dot {
		width: 12px;
		height: 12px;
		border-radius: var(--radius-pill);
		background: var(--color-text);
	}

	.caret {
		width: 2px;
		height: 24px;
		border-radius: 1px;
		background: var(--color-accent);
		animation: blink 1s steps(1) infinite;
	}

	@media (prefers-reduced-motion: reduce) {
		.caret {
			animation: none;
		}
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

		.cells {
			gap: 10px;
		}

		.cell {
			flex: 0 0 52px;
			width: 52px;
		}

		.enhanced input,
		.pin {
			width: 238px;
		}

		.error {
			grid-column: 1 / -1;
			justify-self: end;
		}
	}
</style>
