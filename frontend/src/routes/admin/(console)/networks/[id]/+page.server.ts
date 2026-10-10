import { error, fail, redirect } from '@sveltejs/kit';
import { Effect } from 'effect';
import { SWITCH_KEYS, type SwitchKey } from '#lib/contract/admin.js';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall, newKey, readCommandForm, withStepUp } from '#lib/server/admin.js';
import type { Actions, PageServerLoad } from './$types';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isSwitchKey = (value: unknown): value is SwitchKey =>
	typeof value === 'string' && (SWITCH_KEYS as readonly string[]).includes(value);

const watDay = new Intl.DateTimeFormat('en-CA', {
	year: 'numeric',
	month: '2-digit',
	day: '2-digit',
	timeZone: 'Africa/Lagos'
});

function tenantIdOf(params: { id: string }): string {
	if (!UUID.test(params.id)) error(404, 'Not found');
	return params.id.toLowerCase();
}

export const load: PageServerLoad = async (event) => {
	await event.parent();
	const session = (await event.locals.session())!;
	const id = tenantIdOf(event.params);
	const { network, switches, versions } = await adminCall(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* AdminApi;
			return yield* Effect.all(
				{
					network: api.network(id),
					switches: api.switches(id),
					versions: api.allocationVersions(id)
				},
				{ concurrency: 'unbounded' }
			);
		})
	);
	return {
		title: network.name,
		network,
		switches,
		versions: versions.items,
		today: watDay.format(new Date()),
		activateKey: newKey(),
		switchKey: newKey()
	};
};

const back = (url: URL) => {
	const next = new URL(url);
	for (const key of ['dialog', 'key', '/activate', '/switch']) next.searchParams.delete(key);
	const query = next.searchParams.toString();
	return `${next.pathname}${query ? `?${query}` : ''}`;
};

export const actions: Actions = {
	activate: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, '/admin/sign-in');
		const id = tenantIdOf(event.params);
		const f = await readCommandForm(event);
		if (!('reason' in f)) return f;
		const mode = String(f.form.get('mode') ?? '');
		const untilRaw = String(f.form.get('until') ?? '');
		let until: string | null = null;
		if (mode === 'complimentary') {
			if (!/^\d{4}-\d{2}-\d{2}$/.test(untilRaw)) {
				return fail(400, {
					error: 'Choose the last free day.',
					reason: f.reason,
					mode,
					until: untilRaw
				});
			}
			if (untilRaw < watDay.format(new Date())) {
				return fail(400, {
					error: 'Choose today or a later day.',
					reason: f.reason,
					mode,
					until: untilRaw
				});
			}
			until = untilRaw;
		} else if (mode !== 'development') {
			return fail(400, {
				error: 'Choose how to activate.',
				reason: f.reason,
				mode,
				until: untilRaw
			});
		}
		const result = await withStepUp(
			event,
			session,
			f.pin,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).activate(id, {
					until,
					reason: f.reason,
					idempotencyKey: f.idempotencyKey
				});
			})
		);
		if (!result.ok) {
			return fail(result.status, {
				error: result.message,
				reason: f.reason,
				mode,
				until: untilRaw,
				key: f.idempotencyKey
			});
		}
		redirect(303, back(event.url));
	},
	switch: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, '/admin/sign-in');
		const id = tenantIdOf(event.params);
		const f = await readCommandForm(event);
		if (!('reason' in f)) return f;
		const key = f.form.get('key');
		const stopped = String(f.form.get('stopped') ?? '');
		if (!isSwitchKey(key) || (stopped !== 'true' && stopped !== 'false')) {
			return fail(400, { error: 'Reload the page and try again.', reason: f.reason });
		}
		const result = await withStepUp(
			event,
			session,
			f.pin,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).setSwitch({
					key,
					tenantId: id,
					stopped: stopped === 'true',
					reason: f.reason,
					idempotencyKey: f.idempotencyKey
				});
			})
		);
		if (!result.ok) {
			return fail(result.status, {
				error: result.message,
				reason: f.reason,
				key: f.idempotencyKey
			});
		}
		redirect(303, back(event.url));
	}
};
