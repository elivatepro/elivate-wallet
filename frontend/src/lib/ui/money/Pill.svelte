<!-- Status pill (Paper T03): warning/info/success/danger/neutral tones. -->
<script lang="ts">
	import type { Tone } from '#lib/withdrawals.js';
	let { label, tone, inline = false }: { label: string; tone: Tone; inline?: boolean } = $props();
</script>

<span class="mm-pill {tone}" class:inline>{label}</span>
