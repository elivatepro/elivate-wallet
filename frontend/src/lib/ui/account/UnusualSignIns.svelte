<!--
	Unusual sign-ins (Blueprint 14), Paper "App — Screens v4" Z07 / v2 S03
	(desktop: warning tile, "Windows · Edge · new location", place, sign-in
	time and state, "Not you? Change password" in the 200 px lane) and S04
	(mobile: eyebrow, one card, the link under the text). A sign-in is unusual
	when its city/country or device is new for the account. Never the IP.
-->
<script lang="ts">
	import type { UnusualSignIn } from '#lib/contract/security.js';
	import { placeLabel, signInTime, unusualReason, unusualStatus } from '#lib/devices.js';

	let { items }: { items: ReadonlyArray<UnusualSignIn> } = $props();

	const sentence = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
</script>

{#snippet warning()}
	<svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
		<path
			d="M12 3 2.5 20h19L12 3z"
			fill="none"
			stroke="currentColor"
			stroke-width="1.8"
			stroke-linejoin="round"
		/>
		<path
			d="M12 10v4.5M12 17.2v.1"
			fill="none"
			stroke="currentColor"
			stroke-width="1.8"
			stroke-linecap="round"
		/>
	</svg>
{/snippet}

<section class="group" aria-labelledby="unusual-heading">
	<h2 class="eyebrow" id="unusual-heading">Unusual sign-ins</h2>
	<div class="card">
		<div class="card-head"><h2 class="card-title">Unusual sign-ins</h2></div>
		<ul>
			{#each items as item (item.signInId)}
				{@const reason = unusualReason(item)}
				<li class="row">
					<span class="icon">{@render warning()}</span>
					<span class="who">
						<span class="name">{item.device}<span class="desk">{` · ${reason}`}</span></span>
						<span class="sub">
							<span class="desk">{placeLabel(item.city, item.country) ?? 'Location unknown'}</span>
							<span class="mob"
								>{[
									sentence(reason),
									placeLabel(item.city, item.country, true),
									signInTime(item.signedInAt)
								]
									.filter(Boolean)
									.join(' · ')}</span
							>
						</span>
					</span>
					<span class="when">{unusualStatus(item)}</span>
					<span class="lane"
						><a class="link" href="/app/account/password">Not you? Change password</a></span
					>
				</li>
			{/each}
		</ul>
	</div>
</section>

<style>
	.group {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.eyebrow {
		padding-left: 4px;
		color: var(--color-muted);
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: var(--font-weight-regular);
		letter-spacing: 0.06em;
		line-height: 14px;
		text-transform: uppercase;
	}

	.card {
		display: flex;
		flex-direction: column;
		overflow: clip;
		border: 1px solid #ffffff14;
		border-radius: 18px;
		background: var(--color-surface);
	}

	:global([data-theme='light']) .card {
		border-color: var(--color-border);
	}

	.card-head,
	.desk,
	.when {
		display: none;
	}

	ul {
		margin: 0;
		padding: 0;
		list-style: none;
	}

	/* Mobile (S04): icon and text on one line, the link under the text. */
	.row {
		display: grid;
		grid-template-columns: 24px 1fr;
		column-gap: 12px;
		row-gap: 10px;
		align-items: center;
		padding: 14px 16px;
	}

	.row + .row {
		border-top: 1px solid #ffffff0a;
	}

	:global([data-theme='light']) .row + .row {
		border-top-color: var(--color-border);
	}

	.icon {
		display: flex;
		justify-content: center;
		color: var(--color-warning);
	}

	.who {
		display: flex;
		flex-direction: column;
		gap: 3px;
		min-width: 0;
	}

	.name {
		color: var(--color-text);
		font-size: 15px;
		line-height: 20px;
	}

	.sub {
		color: var(--color-muted);
		font-size: var(--text-12);
		line-height: var(--leading-16);
	}

	.lane {
		grid-column: 2;
	}

	.link {
		color: var(--color-accent-text);
		font-size: 13px;
		font-weight: var(--font-weight-medium);
		line-height: 18px;
		text-decoration: none;
	}

	.link:hover,
	.link:focus-visible {
		text-decoration: underline;
	}

	@media (min-width: 1024px) {
		.eyebrow,
		.mob {
			display: none;
		}

		.desk {
			display: inline;
		}

		.card {
			border-radius: 20px;
		}

		.card-head {
			display: flex;
			align-items: center;
			padding: 18px 22px;
			border-bottom: 1px solid #ffffff0f;
		}

		:global([data-theme='light']) .card-head {
			border-bottom-color: var(--color-border);
		}

		.card-title {
			color: var(--color-text);
			font-size: var(--text-16);
			font-weight: var(--font-weight-semibold);
			line-height: var(--leading-20);
		}

		.row {
			display: flex;
			gap: 16px;
			padding: 16px 22px;
		}

		.icon {
			flex-shrink: 0;
			align-items: center;
			width: 40px;
			height: 40px;
			border-radius: 10px;
			background: var(--color-raised);
		}

		.who {
			flex: 0 1 340px;
		}

		.name {
			font-size: var(--text-14);
			line-height: 18px;
		}

		.when {
			display: block;
			flex: 1 1 0%;
			min-width: 0;
			color: var(--color-muted);
			font-size: 13px;
			line-height: var(--leading-16);
		}

		.lane {
			display: flex;
			flex-shrink: 0;
			justify-content: flex-end;
			min-width: 96px;
		}

		.link {
			line-height: var(--leading-16);
		}
	}

	@media (min-width: 1280px) {
		.lane {
			width: 200px;
		}
	}
</style>
