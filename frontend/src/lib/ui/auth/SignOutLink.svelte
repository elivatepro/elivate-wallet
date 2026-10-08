<!--
	"Back to sign in" from a gate page means ending this session, so it is a POST
	(sign-out), styled like the Paper underline link.
-->
<script lang="ts">
	import { purgeAllDeviceData } from '#lib/client/device-cache.js';

	let { label = 'Back to sign in' }: { label?: string } = $props();
</script>

<form method="POST" action="/sign-out" class="signout" onsubmit={() => purgeAllDeviceData()}>
	<button type="submit">{label}</button>
</form>

<style>
	.signout {
		display: flex;
		justify-content: center;
	}

	button {
		min-height: var(--hit-min);
		padding: 0 8px;
		border: 0;
		background: transparent;
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-20);
		text-decoration: underline 1px var(--auth-link-underline);
		text-underline-offset: 4px;
		cursor: pointer;
	}
</style>
