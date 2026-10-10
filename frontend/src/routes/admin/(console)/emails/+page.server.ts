import { fail, redirect } from '@sveltejs/kit';
import { Effect } from 'effect';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall, newKey, readCommandForm, withStepUp } from '#lib/server/admin.js';
import type { Actions, PageServerLoad } from './$types';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const load: PageServerLoad = async (event) => {
	await event.parent();
	const session = (await event.locals.session())!;
	const { letters, networks } = await adminCall(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* AdminApi;
			return yield* Effect.all(
				{ letters: api.deadLetters, networks: api.networks({}) },
				{ concurrency: 'unbounded' }
			);
		})
	);
	// Network names for the first page of networks (dead letters carry only the id).
	const names = Object.fromEntries(networks.items.map((n) => [n.tenantId, n.name]));
	return { title: 'Failed emails', letters, names, idempotencyKey: newKey() };
};

export const actions: Actions = {
	requeue: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, '/admin/sign-in');
		const f = await readCommandForm(event);
		if (!('reason' in f)) return f;
		const id = String(f.form.get('eventId') ?? '');
		if (!UUID.test(id))
			return fail(400, { error: 'Reload the page and try again.', reason: f.reason });
		const result = await withStepUp(
			event,
			session,
			f.pin,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).requeue(id.toLowerCase(), {
					reason: f.reason,
					idempotencyKey: f.idempotencyKey
				});
			})
		);
		if (result.ok) redirect(303, '/admin/emails');
		return fail(result.status, { error: result.message, reason: f.reason, key: f.idempotencyKey });
	}
};
