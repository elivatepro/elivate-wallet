<!-- Approved draft A01cd / A01cm · This account isn't an admin. -->
<script lang="ts">
	import AuthHeading from '#lib/ui/auth/AuthHeading.svelte';
	import PrimaryButton from '#lib/ui/auth/PrimaryButton.svelte';
	import { useRoot } from '#lib/ui/root.svelte.js';
	import type { PageProps } from './$types';

	let { data }: PageProps = $props();
	useRoot('no-access', 'lg');
</script>

<svelte:head><title>No access · Elivate Admin</title></svelte:head>

<AuthHeading
	eyebrow="No access"
	title="This account isn’t an admin"
	lead="Another Elivate admin can add you."
/>
<form method="POST" action="/admin/sign-out">
	<PrimaryButton label="Use a different account" />
</form>
<a class="alt" href={data.walletUrl}>Open Elivate Wallet</a>

<style>
	form {
		display: flex;
		flex-direction: column;
	}
	.alt {
		display: flex;
		justify-content: center;
		align-items: center;
		min-height: var(--hit-min);
		font-size: 14px;
		color: var(--auth-body);
		text-decoration: none;
	}
</style>
