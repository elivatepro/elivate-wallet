import { Effect } from 'effect';
import { AdminApi } from '#lib/server/apis-admin.js';
import { adminCall, adminPage } from '#lib/server/admin.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = (event) =>
	adminPage(event, async (session) => {
		const restores = await adminCall(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).restores;
			})
		);
		return { title: 'Backups & restores', restores };
	});
