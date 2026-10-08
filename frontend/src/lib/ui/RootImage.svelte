<!-- Decorative Root pose (alt=""): 1×/2× WebP, bottom-anchored like Paper's contain/50% 100%. -->
<script lang="ts">
	import { ROOT_HEIGHTS, rootSrc, rootSrcset, type RootPose } from './root.svelte.js';

	let {
		pose,
		sizes = '390px',
		class: className = '',
		eager = false
	}: { pose: RootPose; sizes?: string; class?: string; eager?: boolean } = $props();
</script>

<img
	class="root {className}"
	src={rootSrc(pose)}
	srcset={rootSrcset(pose)}
	{sizes}
	width="390"
	height={ROOT_HEIGHTS[pose]}
	alt=""
	decoding="async"
	loading={eager ? 'eager' : 'lazy'}
	draggable="false"
/>

<style>
	.root {
		display: block;
		object-fit: contain;
		object-position: 50% 100%;
		user-select: none;
	}
</style>
