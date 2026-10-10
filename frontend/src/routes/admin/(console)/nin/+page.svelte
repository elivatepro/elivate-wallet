<!-- Approved draft A21d / A21m · NIN reviews (approve or reject; reason + PIN). -->
<script lang="ts">
	import { page } from '$app/state';
	import AdminDialog from '#lib/ui/admin/AdminDialog.svelte';
	import RootHero from '#lib/ui/app/RootHero.svelte';
	import { ROLE_NAMES, initials, when, withQuery } from '#lib/admin.js';
	import { plural } from '#lib/ui/admin/MiscText.js';
	import type { NinReview } from '#lib/contract/admin.js';
	import type { PageProps } from './$types';

	let { data, form }: PageProps = $props();
	type FormState = { error?: string; reason?: string; key?: string; decision?: string };
	const fv = $derived(form as FormState | null | undefined);
	const legal = (r: NinReview) =>
		[r.legalName.given, ...(r.legalName.middle ?? []), r.legalName.surname].join(' ');
	const reviewing = $derived(
		page.url.searchParams.get('dialog') === 'review'
			? data.reviews.find((r) => r.reviewId === page.url.searchParams.get('id'))
			: undefined
	);
	const closeHref = $derived(withQuery(page.url, { dialog: null, id: null }));
</script>

<div class="admin-page">
	<RootHero
		pose="member-wallet"
		headingLevel={2}
		title={data.reviews.length === 0
			? 'No identity checks waiting'
			: `${plural(data.reviews.length, 'identity check')} waiting`}
		lead="You never review your own."
	/>

	<section class="admin-card" aria-label="NIN reviews">
		{#if data.reviews.length === 0}
			<p class="admin-empty">Nothing to review.</p>
		{:else}
			<table class="admin-table collapse">
				<thead>
					<tr
						><th>Person</th><th>Name on NIN</th><th>Office</th><th>NIN</th><th class="num"
							>Requested</th
						><th><span class="sr-only">Review</span></th></tr
					>
				</thead>
				<tbody>
					{#each data.reviews as r (r.reviewId)}
						<tr>
							<td>
								<span class="who">
									<span class="tile">{initials(r.requester.name)}</span>
									<span class="who-text">
										<span class="who-name">{r.requester.name ?? r.requester.uid}</span>
										<span class="who-sub">{r.requester.uid} · {ROLE_NAMES[r.role]}</span>
									</span>
								</span>
							</td>
							<td data-label="Name on NIN">{legal(r)}</td>
							<td data-label="Office">{r.officeName ?? '—'}</td>
							<td class="mono" data-label="NIN">•••• {r.ninLast4}</td>
							<td class="num" data-label="Requested">{when(r.requestedAt)}</td>
							<td class="num">
								<a
									class="btn small"
									href={withQuery(page.url, { dialog: 'review', id: r.reviewId })}>Review</a
								>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		{/if}
	</section>
</div>

{#if reviewing}
	<AdminDialog
		pose="member-wallet"
		title="Review identity"
		lead={`${reviewing.requester.name ?? reviewing.requester.uid} · NIN name ${legal(reviewing)}`}
		action="?/decide"
		cancelHref={closeHref}
		submitLabel="Save decision"
		idempotencyKey={fv?.key ?? data.idempotencyKey}
		error={fv?.error ?? null}
		reason={fv?.reason ?? ''}
	>
		<input type="hidden" name="reviewId" value={reviewing.reviewId} />
		<fieldset class="choice">
			<legend class="sr-only">Decision</legend>
			<label class="option">
				<input
					type="radio"
					name="decision"
					value="approve"
					checked={fv?.decision !== 'reject'}
				/>Approve
			</label>
			<label class="option">
				<input
					type="radio"
					name="decision"
					value="reject"
					checked={fv?.decision === 'reject'}
				/>Reject
			</label>
		</fieldset>
	</AdminDialog>
{/if}

<style>
	.mono {
		font-family: var(--font-mono);
		font-size: 13px;
	}
	.choice {
		display: flex;
		gap: 10px;
		margin: 0;
		padding: 0;
		border: 0;
	}
	.option {
		display: flex;
		flex: 1 1 0;
		align-items: center;
		gap: 10px;
		min-height: 52px;
		padding: 0 16px;
		border-radius: 12px;
		border: 1px solid var(--color-border);
		font-size: 14px;
	}
	.option:has(input:checked) {
		background: var(--color-raised);
	}
	.option input {
		accent-color: var(--color-accent);
	}
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
	}
</style>
