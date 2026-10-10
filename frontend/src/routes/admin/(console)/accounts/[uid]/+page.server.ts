import { error, fail, redirect } from '@sveltejs/kit';
import { Effect } from 'effect';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall, newKey, readCommandForm, withStepUp } from '#lib/server/admin.js';
import type { AccountStatus } from '#lib/contract/common.js';
import type { Actions, PageServerLoad } from './$types';

const UID = /^EW-[1-9][0-9]{4,}$/i;
const STATUSES: readonly AccountStatus[] = ['active', 'restricted', 'suspended', 'deactivated'];

function uidOf(params: { uid: string }): string {
	if (!UID.test(params.uid)) error(404, 'Not found');
	return params.uid.toUpperCase();
}

export const load: PageServerLoad = async (event) => {
	await event.parent();
	const session = (await event.locals.session())!;
	const uid = uidOf(event.params);
	const account = await adminCall(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* AdminApi).account(uid);
		})
	);
	return { title: account.name ?? account.uid, account, statusKey: newKey() };
};

export const actions: Actions = {
	status: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, '/admin/sign-in');
		const uid = uidOf(event.params);
		const f = await readCommandForm(event);
		if (!('reason' in f)) return f;
		const status = String(f.form.get('status') ?? '');
		if (!(STATUSES as readonly string[]).includes(status)) {
			return fail(400, {
				error: 'Choose the new status.',
				reason: f.reason,
				key: f.idempotencyKey
			});
		}
		const result = await withStepUp(
			event,
			session,
			f.pin,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).setAccountStatus(uid, {
					status: status as AccountStatus,
					reason: f.reason,
					idempotencyKey: f.idempotencyKey
				});
			})
		);
		if (!result.ok) {
			return fail(result.status, {
				error: result.message,
				reason: f.reason,
				status,
				key: f.idempotencyKey
			});
		}
		redirect(303, `/admin/accounts/${uid}`);
	}
};
