<!-- Approved draft A01dd / A01dm · Set your PIN first (admins use the Wallet PIN). -->
<script lang="ts">
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	useRoot('pin-create', 'lg');
</script>

<svelte:head><title>Set your PIN first · Elivate Admin</title></svelte:head>

<AuthHeading
	eyebrow="One more step"
	title="Set your PIN first"
	lead="Admins use the same 4-digit PIN as the Wallet app."
/>
<div class="actions">
	<a class="primary" href={data.walletUrl}>Open Elivate Wallet</a>
	<form method="POST" action="/admin/sign-out">
		<button type="submit">Use a different account</button>
	</form>
</div>

<style>
	.actions {
		display: flex;
		flex-direction: column;
		align-items: stretch;
		gap: 12px;
	}
	.primary {
		display: flex;
		align-items: center;
		justify-content: center;
		min-height: 56px;
		border-radius: 999px;
		background: var(--button-primary-bg);
		box-shadow: var(--button-primary-glow);
		font-weight: 600;
		color: var(--button-primary-ink);
		text-decoration: none;
	}
	form {
		display: flex;
		justify-content: center;
	}
	button {
		min-height: var(--hit-min);
		border: 0;
		background: transparent;
		font: inherit;
		font-size: 14px;
		color: var(--auth-body);
		cursor: pointer;
	}
</style>
