import { redirect } from '@sveltejs/kit';
import { ADMIN_PATHS } from '#lib/server/admin.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = () => redirect(303, ADMIN_PATHS.signIn);

export const actions: Actions = {
	// Ends this admin Auth session only; PIN proofs cascade in the database.
	default: async ({ locals }) => {
		if (await locals.session()) {
			await locals.supabase().auth.signOut({ scope: 'local' });
		}
		redirect(303, ADMIN_PATHS.signIn);
	}
};
