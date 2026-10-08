import { redirect } from '@sveltejs/kit';
import { SIGN_IN_PATH } from '#lib/gate.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	const session = await locals.session();
	redirect(303, session ? '/app' : SIGN_IN_PATH);
};
