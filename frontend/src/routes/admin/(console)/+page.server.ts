import { Effect } from 'effect';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall } from '#lib/server/admin.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	await event.parent();
	const session = (await event.locals.session())!;
	const overview = await adminCall(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* AdminApi).overview;
		})
	);
	return { title: 'Overview', overview };
};
