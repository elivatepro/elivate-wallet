import { redirect } from '@sveltejs/kit';
import { writeTheme } from '#lib/server/cookies.js';
import { safeNext } from '#lib/gate.js';
import { parseTheme } from '#lib/theme.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = () => redirect(303, '/');

export const actions: Actions = {
	default: async ({ request, cookies, locals }) => {
		const form = await request.formData();
		writeTheme(cookies, parseTheme(String(form.get('theme') ?? '')), locals.secureCookies);
		redirect(303, safeNext(String(form.get('next') ?? '')) ?? '/');
	}
};
