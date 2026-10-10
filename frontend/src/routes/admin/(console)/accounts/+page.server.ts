import { Effect } from 'effect';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall } from '#lib/server/admin.js';
import type { AccountStatus } from '#lib/contract/common.js';
import type { PageServerLoad } from './$types';

const STATUSES: readonly AccountStatus[] = ['active', 'restricted', 'suspended', 'deactivated'];
const isStatus = (value: string | null): value is AccountStatus =>
	value !== null && (STATUSES as readonly string[]).includes(value);

export const load: PageServerLoad = async (event) => {
	await event.parent();
	const session = (await event.locals.session())!;
	const params = event.url.searchParams;
	const q = (params.get('q') ?? '').trim().slice(0, 100);
	const rawStatus = params.get('status');
	const status = isStatus(rawStatus) ? rawStatus : null;
	const cursor = params.get('cursor');
	const page = await adminCall(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* AdminApi).accounts({ q: q || null, status, cursor });
		})
	);
	return { title: 'Accounts', page, q, status, paged: cursor !== null };
};
