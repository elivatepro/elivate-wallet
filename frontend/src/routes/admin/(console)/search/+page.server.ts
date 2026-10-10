import { Effect } from 'effect';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall } from '#lib/server/admin.js';
import type { PageServerLoad } from './$types';

const TABS = ['all', 'accounts', 'references', 'networks', 'offices'] as const;
type Tab = (typeof TABS)[number];

export const load: PageServerLoad = async (event) => {
	await event.parent();
	const session = (await event.locals.session())!;
	const q = (event.url.searchParams.get('q') ?? '').trim().slice(0, 100);
	const tabParam = event.url.searchParams.get('tab') ?? 'all';
	const tab: Tab = (TABS as readonly string[]).includes(tabParam) ? (tabParam as Tab) : 'all';
	// The API needs at least two characters; shorter queries show the empty page.
	const results =
		q.length >= 2
			? await adminCall(
					event,
					session,
					Effect.gen(function* () {
						return yield* (yield* AdminApi).search(q);
					})
				)
			: null;
	return { title: 'Search', q, tab, results };
};
