<!-- Phone (Paper 09): "+234" chip and the local number. Locked when it came from the NIN record. -->
<script lang="ts">
	let {
		value = '',
		locked = false,
		error
	}: { value?: string; locked?: boolean; error?: string | null } = $props();

	const local = $derived(value.replace(/^\+234/, '').replace(/^0/, ''));
</script>

<div class="field">
	<label for="phone">Phone number</label>
	<div class="control" class:invalid={!!error} class:locked>
		<span class="cc" aria-hidden="true"><span class="flag"></span>+234</span>
		<input
			id="phone"
			name="phone"
			type="tel"
			inputmode="tel"
			autocomplete="tel-national"
			placeholder="803 214 5678"
			value={local}
			readonly={locked}
			aria-invalid={error ? 'true' : undefined}
			aria-describedby={error ? 'phone-error' : locked ? 'phone-hint' : undefined}
		/>
	</div>
	{#if error}
		<p class="error" id="phone-error">{error}</p>
	{:else if locked}
		<p class="hint" id="phone-hint">From your national ID record.</p>
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
		gap: 12px;
		height: 52px;
		padding: 0 16px 0 8px;
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

	.control.locked {
		border-style: dashed;
	}

	.cc {
		display: flex;
		align-items: center;
		gap: 8px;
		height: 36px;
		padding: 0 10px;
		border-radius: var(--radius-8);
		background: color-mix(in oklab, var(--color-text) 8%, transparent);
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
	}

	.flag {
		width: 18px;
		height: 12px;
		border-radius: 2px;
		background: linear-gradient(90deg, #118c4f 33%, #fff 33% 66%, #118c4f 66%);
	}

	input {
		flex: 1;
		min-width: 0;
		height: 100%;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font-size: 15px;
		outline: none;
	}

	.hint {
		color: var(--auth-body);
		font-size: var(--text-12);
	}

	.error {
		color: var(--color-danger);
		font-size: var(--text-14);
	}
</style>
