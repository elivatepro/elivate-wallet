import { fail, redirect } from '@sveltejs/kit';
import { Effect } from 'effect';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall, adminPage, newKey, readCommandForm, withStepUp } from '#lib/server/admin.js';
import type { Actions, PageServerLoad } from './$types';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const load: PageServerLoad = (event) =>
	adminPage(event, async (session) => {
		const reviews = await adminCall(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).ninReviews;
			})
		);
		return { title: 'NIN reviews', reviews, idempotencyKey: newKey() };
	});

export const actions: Actions = {
	decide: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, '/admin/sign-in');
		const f = await readCommandForm(event);
		if (!('reason' in f)) return f;
		const id = String(f.form.get('reviewId') ?? '');
		const decision = String(f.form.get('decision') ?? '');
		if (!UUID.test(id) || (decision !== 'approve' && decision !== 'reject')) {
			return fail(400, {
				error: 'Choose approve or reject.',
				reason: f.reason,
				key: f.idempotencyKey
			});
		}
		const result = await withStepUp(
			event,
			session,
			f.pin,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).decideNin(id.toLowerCase(), {
					decision,
					reason: f.reason,
					idempotencyKey: f.idempotencyKey
				});
			})
		);
		if (result.ok) redirect(303, '/admin/nin');
		return fail(result.status, {
			error: result.message,
			reason: f.reason,
			decision,
			key: f.idempotencyKey
		});
	}
};
