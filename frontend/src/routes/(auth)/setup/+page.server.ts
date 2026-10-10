// Founder setup (Blueprint 16, W-19; Paper PL01/PL02, PL11): name the
// network, choose a launch band, and either start the founder's one 7-day
// trial or go to payment. The backend enforces one trial per founder ever.

import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { IDEMPOTENCY_KEY_PATTERN, UUID_PATTERN } from '#lib/contract/common.js';
import { BillingApi } from '#lib/server/apis-billing.js';
import { describeFailure } from '#lib/server/setup.js';
import { callOrRedirect, expectGate, failureOf, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import { listWorkspaces, newIdempotencyKey, selectWorkspace } from '#lib/server/workspace.js';
import type { Actions, PageServerLoad } from './$types';

const PLAN_KEYS = ['band_400', 'band_1000', 'band_1001_plus'] as const;

export const load: PageServerLoad = async (event) => {
	const { session } = await expectGate(event, 'ready');
	const setup = await callOrRedirect(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* BillingApi).setup;
		})
	);
	// Founders apply first (Blueprint 19); the application form says how.
	if (!setup.founderApproved) redirect(303, '/apply');
	return { setup, idempotencyKey: newIdempotencyKey() };
};

/** The short name: the first word, up to 30 characters ("Cedar Network" → "Cedar"). */
const shortNameOf = (name: string) => (name.split(/\s+/)[0] ?? name).slice(0, 30);

async function open(
	event: Parameters<Actions['start']>[0],
	session: Awaited<ReturnType<typeof expectGate>>['session'],
	membershipId: string
) {
	const workspaces = await listWorkspaces(event, session);
	const created = workspaces.find((w) => w.membershipId === membershipId);
	return created ? selectWorkspace(event, session, created) : false;
}

export const actions: Actions = {
	start: async (event) => {
		const { session } = await expectGate(event, 'ready');
		const form = await event.request.formData();
		const name = String(form.get('name') ?? '')
			.trim()
			.replace(/\s+/g, ' ');
		const planKey = String(form.get('planKey') ?? '');
		const trial = form.get('trial') === 'true';
		const idempotencyKey = String(form.get('idempotencyKey') ?? '');
		if (name.length < 2 || name.length > 100) {
			return fail(400, { name, step: 'name', errors: { name: 'Use 2–100 characters.' } });
		}
		if (
			!(PLAN_KEYS as readonly string[]).includes(planKey) ||
			!IDEMPOTENCY_KEY_PATTERN.test(idempotencyKey)
		) {
			return fail(400, { name, step: 'plan', message: 'Choose a plan and try again.' });
		}
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* BillingApi).startNetwork({
					name,
					shortName: shortNameOf(name),
					planKey,
					trial: trial && planKey === 'band_400',
					idempotencyKey
				});
			})
		);
		if (Exit.isFailure(exit)) {
			const failure = failureOf(exit);
			if (
				failure._tag === 'BackendError' &&
				failure.code === 'authorization_denied' &&
				failure.details.reason === 'founder_not_approved'
			) {
				redirect(303, '/apply');
			}
			const message = describeFailure(failure);
			if (message) return fail(409, { name, step: 'plan', message, idempotencyKey });
			redirectForFailure(failure);
		}
		const started = exit.value;
		if (!(await open(event, session, started.membershipId))) redirect(303, '/workspaces?switch');
		// A trial opens at once (PL04); otherwise Paystack comes first (PL03).
		redirect(303, started.status === 'active' ? '/app/billing' : '/setup/pay');
	},

	/** A network already awaiting payment: open it and go to payment. */
	resume: async (event) => {
		const { session } = await expectGate(event, 'ready');
		const form = await event.request.formData();
		const membershipId = String(form.get('membershipId') ?? '');
		if (!UUID_PATTERN.test(membershipId) || !(await open(event, session, membershipId))) {
			return fail(409, {
				step: 'plan',
				message: 'That network can’t be opened. Reload and try again.'
			});
		}
		redirect(303, '/setup/pay');
	}
};
