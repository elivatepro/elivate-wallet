<!--
	Install step picture in Root's place (Blueprint 35): a tilted home screen
	with the app's tile on phones (Paper "Install app v9" IA01/IA02), a dock
	with the app raised on computers (IA03). Decorative only.
-->
<script lang="ts">
	let { desktop = false }: { desktop?: boolean } = $props();
</script>

{#if desktop}
	<div class="dock-wrap">
		<span class="tooltip">Elivate Wallet</span>
		<div class="dock">
			<span class="app" style:background="#82b8e8"></span>
			<span class="app" style:background="#f2f4f4"></span>
			<span class="app" style:background="#43c48b"></span>
			<span class="ours">
				<img src="/icons/icon-192.png" alt="" width="88" height="88" />
				<span class="running"></span>
			</span>
			<span class="app" style:background="#f2b85e"></span>
			<span class="app" style:background="#5e686b"></span>
		</div>
	</div>
{:else}
	<div class="home">
		{#each [0, 1, 2] as row (row)}
			<div class="row" class:faded={row === 2}>
				{#each [0, 1, 2, 3] as col (col)}
					{#if row === 1 && col === 1}
						<span class="ours">
							<img src="/icons/icon-192.png" alt="" width="52" height="52" />
							<span class="label">Wallet</span>
						</span>
					{:else}
						<span class="tile"></span>
					{/if}
				{/each}
			</div>
		{/each}
	</div>
{/if}

<style>
	.home {
		display: flex;
		flex-direction: column;
		gap: 18px;
		padding: 22px 24px;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: 32px;
		background: color-mix(in oklab, var(--color-canvas) 55%, transparent);
		backdrop-filter: blur(16px);
		transform: rotate(-4deg);
	}

	.row {
		display: flex;
		align-items: flex-start;
		gap: 18px;
	}

	.row.faded {
		opacity: 0.5;
	}

	.tile {
		width: 52px;
		height: 52px;
		border-radius: 14px;
		background: color-mix(in oklab, var(--color-text) 6%, transparent);
	}

	.home .ours {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 14px;
		width: 52px;
	}

	.home .ours img {
		width: 52px;
		height: 52px;
		border: 1px solid color-mix(in oklab, var(--color-accent) 70%, transparent);
		border-radius: 14px;
		box-shadow:
			color-mix(in oklab, var(--color-accent) 65%, transparent) 0 10px 36px -4px,
			#ffffff26 0 1px 0 inset;
		transform: scale(1.18);
	}

	.label {
		color: var(--color-text);
		font-size: var(--text-12);
		font-weight: var(--font-weight-medium);
		line-height: var(--leading-16);
	}

	.dock-wrap {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 14px;
		transform: rotate(-4deg);
		zoom: 0.62;
	}

	.tooltip {
		padding: 6px 12px;
		border: 1px solid color-mix(in oklab, var(--color-text) 8%, transparent);
		border-radius: var(--radius-8);
		background: color-mix(in oklab, var(--color-raised) 95%, transparent);
		color: var(--color-text);
		font-size: var(--text-14);
		font-weight: var(--font-weight-medium);
		line-height: 18px;
	}

	.dock {
		display: flex;
		align-items: flex-end;
		gap: 12px;
		padding: 12px 14px;
		border: 1px solid color-mix(in oklab, var(--color-text) 12%, transparent);
		border-radius: var(--radius-24);
		background: color-mix(in oklab, var(--color-canvas) 55%, transparent);
		backdrop-filter: blur(16px);
	}

	.app {
		width: 64px;
		height: 64px;
		border-radius: 15px;
	}

	.dock .ours {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 6px;
	}

	.dock .ours img {
		width: 88px;
		height: 88px;
		border-radius: 20px;
		box-shadow: color-mix(in oklab, var(--color-accent) 55%, transparent) 0 12px 36px -6px;
	}

	.running {
		width: 5px;
		height: 5px;
		border-radius: var(--radius-pill);
		background: var(--color-text);
	}

	@media (min-width: 1024px) {
		.dock-wrap {
			zoom: 1;
		}
	}
</style>
