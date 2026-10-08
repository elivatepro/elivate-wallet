import { requireSession } from '#lib/server/flow.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	await requireSession(event);
	return {};
};
