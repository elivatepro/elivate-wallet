<!--
	Notifications step picture in Root's place (Blueprint 42; Paper "Push
	notifications v13" PN01): two lock-screen notifications, tilted, in the
	Part A wording. Decorative only; synthetic amounts.
-->
<div class="stack" aria-hidden="true">
	<div class="note">
		<span class="tile"><img src="/icons/mark.svg" alt="" width="22" height="22" /></span>
		<span class="text">
			<span class="top"><span class="title">Income posted</span><span class="time">now</span></span>
			<span class="line">₦250,000.00, split across your pockets</span>
		</span>
	</div>
	<div class="note faded">
		<span class="tile"><img src="/icons/mark.svg" alt="" width="22" height="22" /></span>
		<span class="text">
			<span class="top"
				><span class="title">Withdrawal to approve</span><span class="time">2m ago</span></span
			>
			<span class="line">₦85,000.00 is waiting for you</span>
		</span>
	</div>
</div>

<style>
	.stack {
		display: flex;
		flex-direction: column;
		gap: 12px;
		width: 318px;
		transform: rotate(-4deg);
	}

	.note {
		display: flex;
		align-items: flex-start;
		gap: 12px;
		padding: 14px 16px;
		border: 1px solid #ffffff14;
		border-radius: var(--radius-24);
		background: #2a2e30d9;
		backdrop-filter: blur(20px);
		box-shadow: #00000066 0 18px 40px -12px;
	}

	.note.faded {
		opacity: 0.72;
	}

	.tile {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		width: 38px;
		height: 38px;
		border: 1px solid color-mix(in oklab, var(--color-accent) 50%, transparent);
		border-radius: 10px;
		background: #111314;
	}

	.tile img {
		width: 22px;
		height: 22px;
	}

	.text {
		display: flex;
		flex: 1;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.top {
		display: flex;
		justify-content: space-between;
		gap: 8px;
	}

	.title {
		color: #f2f4f4;
		font-size: var(--text-14);
		font-weight: var(--font-weight-semibold);
		line-height: 18px;
	}

	.time {
		flex-shrink: 0;
		color: #a9b0b3;
		font-size: var(--text-12);
		line-height: 18px;
	}

	.line {
		color: #d5dadb;
		font-size: var(--text-14);
		line-height: var(--leading-20);
	}

	@media (min-width: 1024px) {
		.stack {
			width: 360px;
		}
	}
</style>
