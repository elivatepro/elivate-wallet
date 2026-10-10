<!--
	Profile photo (Paper 09): dashed coral circle with a camera, preview after a
	choice. A real file input (works without JS); JPEG, PNG or WebP up to 5 MB,
	checked again on the server. With JavaScript, the chosen photo is shrunk to
	512 px and re-encoded before the form posts it (slice 21).
-->
<script lang="ts">
	import Camera from '@lucide/svelte/icons/camera';
	import { shrinkInputPhoto } from '#lib/client/photo.js';

	let {
		hasPhoto = false,
		photoSrc = null,
		required = true,
		converting = $bindable(false),
		error
	}: {
		hasPhoto?: boolean;
		photoSrc?: string | null;
		required?: boolean;
		/** True while a chosen photo is being shrunk; the form waits for it. */
		converting?: boolean;
		error?: string | null;
	} = $props();

	let preview = $state<string | null>(null);
	const onChange = async (event: Event) => {
		const input = event.currentTarget as HTMLInputElement;
		const chosen = input.files?.[0] ?? null;
		if (preview) URL.revokeObjectURL(preview);
		preview = null;
		converting = !!chosen;
		const file = await shrinkInputPhoto(input);
		// Only the latest choice updates the preview (a newer one may be converting).
		if (input.files?.[0] !== chosen && input.files?.[0] !== file) return;
		converting = false;
		preview = file ? URL.createObjectURL(file) : null;
	};
	const shown = $derived(preview ?? (hasPhoto ? photoSrc : null));
</script>

<div class="photo">
	<label
		class="circle"
		class:filled={!!shown}
		class:invalid={!!error}
		aria-busy={converting ? 'true' : undefined}
	>
		{#if shown}
			<img src={shown} alt="" />
		{:else}
			<Camera size={20} strokeWidth={1.6} aria-hidden="true" />
		{/if}
		<input
			type="file"
			name="photo"
			accept="image/jpeg,image/png,image/webp"
			required={required && !hasPhoto}
			aria-label="Profile photo"
			aria-describedby="photo-note"
			onchange={onChange}
		/>
	</label>
	<div class="text">
		<p class="title">Profile photo</p>
		<p class="note" id="photo-note" class:err={!!error}>
			{error ??
				(shown ? 'Tap to change it' : `${required ? 'Required · ' : ''}Tap the camera to add one`)}
		</p>
	</div>
</div>

<style>
	.photo {
		display: flex;
		align-items: center;
		gap: 16px;
	}

	.circle {
		position: relative;
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 60px;
		height: 60px;
		border-radius: var(--radius-pill);
		border: 1px dashed color-mix(in oklab, var(--color-accent) 60%, transparent);
		background: color-mix(in oklab, var(--color-accent) 8%, transparent);
		color: var(--color-accent-label);
		overflow: hidden;
		cursor: pointer;
	}

	.circle.filled {
		border-style: solid;
	}

	.circle.invalid {
		border-color: var(--color-danger);
	}

	.circle:focus-within {
		box-shadow: color-mix(in oklab, var(--color-accent) 30%, transparent) 0 0 0 3px;
	}

	img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	input {
		position: absolute;
		inset: 0;
		opacity: 0;
		cursor: pointer;
	}

	.title {
		color: var(--color-text);
		font-size: 15px;
		font-weight: var(--font-weight-semibold);
		line-height: var(--leading-20);
	}

	.note {
		color: var(--auth-body);
		font-size: 13px;
		line-height: 18px;
	}

	.note.err {
		color: var(--color-danger);
	}
</style>
