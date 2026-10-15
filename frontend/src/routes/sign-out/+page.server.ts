import { redirect } from '@sveltejs/kit';
import { clearWorkspace } from '#lib/server/cookies.js';
import { SIGN_IN_PATH } from '#lib/gate.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = () => redirect(303, SIGN_IN_PATH);

export const actions: Actions = {
	// Ends this Auth session only (plan §7.5); PIN proofs cascade in the database.
	default: async ({ locals, cookies, request }) => {
		if (await locals.session()) {
			await locals.supabase().auth.signOut({ scope: 'local' });
		}
		clearWorkspace(cookies);
		// Blueprint 38: "Not you? Sign out" on the team join page goes back to it.
		const next = (await request.formData().catch(() => null))?.get('next');
		redirect(303, next === '/team-join' ? '/team-join' : SIGN_IN_PATH);
	}
};
