import { expectGate } from '#lib/server/flow.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	await expectGate(event, 'pin_locked');
	return {};
};
