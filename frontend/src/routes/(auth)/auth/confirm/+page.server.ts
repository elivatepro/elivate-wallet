// Landing page for every emailed Auth link (decision 38, plan §7.1/§7.4).
// GET never consumes the token, so link scanners cannot burn it; the person
// presses Continue, which POSTs and calls verifyOtp. The session lands in
// HttpOnly cookies and the browser is redirected to a clean URL.

import { redirect } from '@sveltejs/kit';
import {
	clearWorkspace,
	markFounderPasswordNeeded,
	markJoinPasswordNeeded,
	markRecovery,
	readFounderToken,
	readJoinToken
} from '#lib/server/cookies.js';
import { recordSignIn } from '#lib/server/sign-ins.js';
import type { SignInMethod } from '#lib/contract/security.js';
import type { Actions, PageServerLoad } from './$types';

const LINK_TYPES = ['signup', 'email', 'magiclink', 'recovery'] as const;
type LinkType = (typeof LINK_TYPES)[number];

const METHODS = {
	signup: 'sign_up',
	email: 'sign_up',
	magiclink: 'email_link',
	recovery: 'recovery'
} as const satisfies Record<LinkType, SignInMethod>;

const TOKEN_HASH = /^[A-Za-z0-9_-]{8,256}$/;

function parse(tokenHash: unknown, type: unknown): { tokenHash: string; type: LinkType } | null {
	if (typeof tokenHash !== 'string' || !TOKEN_HASH.test(tokenHash)) return null;
	if (typeof type !== 'string' || !(LINK_TYPES as readonly string[]).includes(type)) return null;
	return { tokenHash, type: type as LinkType };
}

export const load: PageServerLoad = ({ url, cookies }) => {
	const link = parse(url.searchParams.get('token_hash'), url.searchParams.get('type'));
	if (!link) redirect(303, '/auth/link-expired');
	// Same rule as the action: with an invitation open here, any link continues
	// the join, so a Magic Link is not a PIN reset.
	return { tokenHash: link.tokenHash, type: link.type, joining: !!readJoinToken(cookies) || !!readFounderToken(cookies) };
};

export const actions: Actions = {
	default: async (event) => {
		const { request, locals, cookies } = event;
		const form = await request.formData();
		const link = parse(form.get('token_hash'), form.get('type'));
		if (!link) redirect(303, '/auth/link-expired');

		const { error } = await locals
			.supabase()
			.auth.verifyOtp({ token_hash: link.tokenHash, type: link.type });
		if (error) redirect(303, '/auth/link-expired');
		// Blueprint 14: every emailed link opens a new session; record it.
		await recordSignIn(event, METHODS[link.type]);

		clearWorkspace(cookies);
		// Password recovery (Blueprint 10): the Recovery link signs the person in
		// for this one purpose; they choose a new password, then the PIN as usual.
		if (link.type === 'recovery') {
			markRecovery(cookies, locals.secureCookies);
			redirect(303, '/reset-password');
		}
		// An invitation opened in this browser asked Auth for this email (W-02):
		// a sign-up link means the email created the account, which still needs
		// a password; either way the join page continues. Without that cookie a
		// magic link can only be a PIN reset.
		if (readJoinToken(cookies)) {
			if (link.type === 'signup') markJoinPasswordNeeded(cookies, locals.secureCookies);
			redirect(303, '/join');
		}
		// The same for a founder invitation (Blueprint 19).
		if (readFounderToken(cookies)) {
			if (link.type === 'signup') markFounderPasswordNeeded(cookies, locals.secureCookies);
			redirect(303, '/founder');
		}
		// PIN reset links (Magic Link template) continue to the new-PIN form;
		// sign-up confirmations continue through the gate (normally PIN setup).
		redirect(303, link.type === 'magiclink' ? '/pin/reset' : '/workspaces');
	}
};
