import { redirect } from '@sveltejs/kit';
import { adminGateState, adminPathForGate } from '#lib/server/admin.js';
import { walletUrl } from '#lib/server/config.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { state } = await adminGateState(event);
	if (state.gate !== 'pin_setup_required') redirect(303, adminPathForGate(state.gate));
	return { walletUrl: walletUrl() };
};
