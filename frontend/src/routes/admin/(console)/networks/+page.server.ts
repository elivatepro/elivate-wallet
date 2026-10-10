import { Effect } from 'effect';
import { NETWORK_STATES, type NetworkState } from '#lib/contract/admin.js';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall } from '#lib/server/admin.js';
import type { PageServerLoad } from './$types';

const isState = (value: string | null): value is NetworkState =>
	value !== null && (NETWORK_STATES as readonly string[]).includes(value);

export const load: PageServerLoad = async (event) => {
	await event.parent();
	const session = (await event.locals.session())!;
	const params = event.url.searchParams;
	const q = (params.get('q') ?? '').trim().slice(0, 100);
	const rawState = params.get('state');
	const state = isState(rawState) ? rawState : null;
	const cursor = params.get('cursor');
	const page = await adminCall(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* AdminApi).networks({ q: q || null, state, cursor });
		})
	);
	return { title: 'Networks', page, q, state, paged: cursor !== null };
};
