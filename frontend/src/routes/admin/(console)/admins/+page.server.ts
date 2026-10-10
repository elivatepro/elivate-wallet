import { fail, redirect, type RequestEvent } from '@sveltejs/kit';
import { Effect } from 'effect';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall, adminPage, newKey, readCommandForm, withStepUp } from '#lib/server/admin.js';
import type { Actions, PageServerLoad } from './$types';

const UID = /^EW-[1-9][0-9]{4,}$/i;

export const load: PageServerLoad = (event) =>
	adminPage(event, async (session) => {
		const admins = await adminCall(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).admins;
			})
		);
		return { title: 'Admins', admins, idempotencyKey: newKey() };
	});

async function change(event: RequestEvent, grant: boolean) {
	const session = await event.locals.session();
	if (!session) redirect(303, '/admin/sign-in');
	const f = await readCommandForm(event);
	if (!('reason' in f)) return f;
	const targetUid = String(f.form.get('targetUid') ?? '')
		.trim()
		.toUpperCase();
	if (!UID.test(targetUid)) {
		return fail(400, {
			error: 'Enter a Wallet UID like EW-48213.',
			reason: f.reason,
			key: f.idempotencyKey
		});
	}
	const result = await withStepUp(
		event,
		session,
		f.pin,
		Effect.gen(function* () {
			const api = yield* AdminApi;
			const input = { targetUid, reason: f.reason, idempotencyKey: f.idempotencyKey };
			return yield* grant ? api.grantAdmin(input) : api.revokeAdmin(input);
		})
	);
	if (result.ok) redirect(303, '/admin/admins');
	return fail(result.status, {
		error: result.status === 404 ? 'No account has that UID.' : result.message,
		reason: f.reason,
		targetUid,
		key: f.idempotencyKey
	});
}

export const actions: Actions = {
	grant: (event) => change(event, true),
	revoke: (event) => change(event, false)
};
