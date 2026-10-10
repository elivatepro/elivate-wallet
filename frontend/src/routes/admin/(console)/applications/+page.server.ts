// Founder applications (Blueprint 19; approved drafts A22d/A22m and the
// A22b review dialog). Approve emails a founder invitation, not approved
// emails a polite no; both need a reason and the PIN. Resend issues a new
// link for an approved application not yet accepted.

import { fail, redirect } from '@sveltejs/kit';
import { Effect } from 'effect';
import { APPLICATION_STATUSES, type ApplicationStatus } from '#lib/contract/admin.js';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall, newKey, readCommandForm, withStepUp } from '#lib/server/admin.js';
import type { Actions, PageServerLoad } from './$types';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const isStatus = (value: string | null): value is ApplicationStatus =>
	value !== null && (APPLICATION_STATUSES as readonly string[]).includes(value);

export const load: PageServerLoad = async (event) => {
	await event.parent();
	const session = (await event.locals.session())!;
	const params = event.url.searchParams;
	const raw = params.get('status');
	const status = isStatus(raw) ? raw : 'waiting';
	const cursor = params.get('cursor');
	const applications = await adminCall(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* AdminApi).applications({ status, cursor });
		})
	);
	return {
		title: 'Founder applications',
		applications,
		status,
		paged: cursor !== null,
		idempotencyKey: newKey()
	};
};

const back = (url: URL) => {
	const status = url.searchParams.get('status');
	return isStatus(status) && status !== 'waiting'
		? `/admin/applications?status=${status}`
		: '/admin/applications';
};

export const actions: Actions = {
	decide: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, '/admin/sign-in');
		const f = await readCommandForm(event);
		if (!('reason' in f)) return f;
		const id = String(f.form.get('applicationId') ?? '');
		const decision = String(f.form.get('decision') ?? '');
		if (!UUID.test(id) || (decision !== 'approve' && decision !== 'reject')) {
			return fail(400, {
				error: 'Choose approve or not approved.',
				reason: f.reason,
				key: f.idempotencyKey
			});
		}
		const result = await withStepUp(
			event,
			session,
			f.pin,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).decideApplication(id.toLowerCase(), {
					decision,
					reason: f.reason,
					idempotencyKey: f.idempotencyKey
				});
			})
		);
		if (result.ok) redirect(303, back(event.url));
		return fail(result.status, {
			error: result.message,
			reason: f.reason,
			decision,
			key: f.idempotencyKey
		});
	},

	resend: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, '/admin/sign-in');
		const f = await readCommandForm(event);
		if (!('reason' in f)) return f;
		const id = String(f.form.get('applicationId') ?? '');
		if (!UUID.test(id)) {
			return fail(400, { error: 'Reload and try again.', reason: f.reason, key: f.idempotencyKey });
		}
		const result = await withStepUp(
			event,
			session,
			f.pin,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).resendApplication(id.toLowerCase(), {
					reason: f.reason,
					idempotencyKey: f.idempotencyKey
				});
			})
		);
		if (result.ok) redirect(303, back(event.url));
		return fail(result.status, { error: result.message, reason: f.reason, key: f.idempotencyKey });
	}
};
