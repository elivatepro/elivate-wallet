import { fail, redirect, type RequestEvent } from '@sveltejs/kit';
import { Effect } from 'effect';
import { SWITCH_KEYS, type SwitchKey } from '#lib/contract/admin.js';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall, adminPage, newKey, readCommandForm, withStepUp } from '#lib/server/admin.js';
import type { Actions, PageServerLoad } from './$types';

const isKey = (value: unknown): value is SwitchKey =>
	typeof value === 'string' && (SWITCH_KEYS as readonly string[]).includes(value);

export const load: PageServerLoad = (event) =>
	adminPage(event, async (session) => {
		const switches = await adminCall(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).switches();
			})
		);
		return { title: 'Kill switches', switches, idempotencyKey: newKey() };
	});

async function change(event: RequestEvent, stopped: boolean) {
	const session = await event.locals.session();
	if (!session) redirect(303, '/admin/sign-in');
	const f = await readCommandForm(event);
	if (!('reason' in f)) return f;
	const key = f.form.get('key');
	if (!isKey(key)) return fail(400, { error: 'Reload the page and try again.', reason: f.reason });
	const result = await withStepUp(
		event,
		session,
		f.pin,
		Effect.gen(function* () {
			return yield* (yield* AdminApi).setSwitch({
				key,
				tenantId: null,
				stopped,
				reason: f.reason,
				idempotencyKey: f.idempotencyKey
			});
		})
	);
	if (result.ok) redirect(303, '/admin/switches');
	return fail(result.status, { error: result.message, reason: f.reason });
}

export const actions: Actions = {
	stop: (event) => change(event, true),
	start: (event) => change(event, false)
};
