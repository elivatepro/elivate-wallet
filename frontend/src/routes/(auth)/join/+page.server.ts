// Emailed invitation link (W-02, Blueprint 03 B2/B4; Paper "Authentication v2"
// 08 Invitation verification, 09 Set password, 10 Invitation unavailable).
//
// The link is `/join#t=<token>`: the fragment never reaches a server. The page
// posts it once (`claim`), the server checks it with POST /preview and keeps
// it in an HttpOnly cookie, so the URL stays clean and the token survives the
// Auth email round trip. Then, by state:
//   signed out          → masked bound email + "Verify email" (POST /verify-email;
//                          the server derives the address, the form has no email)
//   signed in, new      → first password (the verification email created the account)
//   signed in           → accept (POST /accept with the token), gate `ready` or
//                          `pin_setup_required` (Blueprint 03 Q7)
// Every unknown/expired/revoked/used token gets the same "unavailable" page.

import { fail, redirect, type RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { IDEMPOTENCY_KEY_PATTERN } from '#lib/contract/common.js';
import { INVITATION_TOKEN_PATTERN } from '#lib/contract/invitations.js';
import { GATE_PATHS } from '#lib/gate.js';
import { maskEmail } from '#lib/labels.js';
import { InvitationsApi } from '#lib/server/apis.js';
import { authFailureFrom, type VerifiedSession } from '#lib/server/auth.js';
import {
	clearJoin,
	clearJoinPasswordNeeded,
	joinPasswordNeeded,
	readJoinToken,
	writeJoinToken
} from '#lib/server/cookies.js';
import { failureOf, isBackendError, loadState, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import { writeOnboardingMembership } from '#lib/server/onboarding.js';
import { newIdempotencyKey } from '#lib/server/workspace.js';
import { MAX_PASSWORD, MIN_PASSWORD } from '../credentials';
import type { Actions, PageServerLoad } from './$types';

const JOIN_PATH = '/join';

/** Gates that may accept an invitation (Blueprint 03 Q7). */
async function acceptingState(event: RequestEvent, session: VerifiedSession) {
	const { state } = await loadState(event);
	if (state.gate === 'pin_required') redirect(303, `${GATE_PATHS.pin_required}?next=${JOIN_PATH}`);
	if (state.gate === 'pin_locked') redirect(303, GATE_PATHS.pin_locked);
	return { session, state };
}

/** POST /preview without a session. `null` means unavailable (cookie cleared). */
async function preview(event: RequestEvent, token: string): Promise<string | null> {
	const exit = await runApi(
		event,
		null,
		Effect.gen(function* () {
			const api = yield* InvitationsApi;
			return yield* api.preview(token);
		})
	);
	if (Exit.isSuccess(exit)) return exit.value.email;
	const failure = failureOf(exit);
	if (
		isBackendError(failure, 'invitation_unavailable') ||
		isBackendError(failure, 'validation_error')
	) {
		clearJoin(event.cookies);
		return null;
	}
	redirectForFailure(failure);
}

const unavailable = () => ({ mode: 'unavailable' as const });

export const load: PageServerLoad = async (event) => {
	const token = readJoinToken(event.cookies);
	// The page reads `#t=` in the browser and posts it to `claim`.
	if (!token) return { mode: 'claim' as const };

	const email = await preview(event, token);
	if (email === null) return unavailable();

	const session = await event.locals.session();
	if (!session) return { mode: 'verify' as const, maskedEmail: maskEmail(email) };

	await acceptingState(event, session);
	if (joinPasswordNeeded(event.cookies)) {
		return { mode: 'password' as const, email: session.email ?? '' };
	}
	return {
		mode: 'accept' as const,
		email: session.email ?? '',
		idempotencyKey: newIdempotencyKey()
	};
};

export const actions: Actions = {
	claim: async (event) => {
		const form = await event.request.formData();
		const token = String(form.get('token') ?? '');
		if (!INVITATION_TOKEN_PATTERN.test(token)) {
			clearJoin(event.cookies);
			return fail(410, { unavailable: true });
		}
		const email = await preview(event, token);
		if (email === null) return fail(410, { unavailable: true });
		writeJoinToken(event.cookies, token, event.locals.secureCookies);
		redirect(303, JOIN_PATH);
	},

	verify: async (event) => {
		const token = readJoinToken(event.cookies);
		if (!token) return fail(410, { unavailable: true });
		const exit = await runApi(
			event,
			null,
			Effect.gen(function* () {
				const api = yield* InvitationsApi;
				return yield* api.verifyEmail(token);
			})
		);
		if (Exit.isSuccess(exit)) return { sent: true };
		const failure = failureOf(exit);
		if (isBackendError(failure, 'invitation_unavailable')) {
			clearJoin(event.cookies);
			return fail(410, { unavailable: true });
		}
		if (isBackendError(failure, 'rate_limited')) {
			return fail(429, { message: 'We sent one recently. Check your inbox or try again later.' });
		}
		if (failure._tag === 'TransportError' || isBackendError(failure, 'internal_error')) {
			return fail(503, { message: 'We couldn’t send the email right now. Try again shortly.' });
		}
		redirectForFailure(failure);
	},

	password: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, JOIN_PATH);
		if (!joinPasswordNeeded(event.cookies)) redirect(303, JOIN_PATH);
		const password = String((await event.request.formData()).get('password') ?? '');
		if (password.length < MIN_PASSWORD) {
			return fail(400, { error: `Use at least ${MIN_PASSWORD} characters.` });
		}
		if (password.length > MAX_PASSWORD) return fail(400, { error: 'That password is too long.' });

		// The verified session sets its own password (W-02 step 4); no API route.
		const { error } = await event.locals.supabase().auth.updateUser({ password });
		if (error && error.code !== 'same_password') {
			const failure = authFailureFrom(error);
			if (failure.kind === 'weak_password') {
				return fail(400, { error: `Use at least ${MIN_PASSWORD} characters.` });
			}
			return fail(failure.kind === 'rate_limited' ? 429 : 503, {
				message:
					failure.kind === 'rate_limited'
						? 'Too many attempts. Wait a few minutes, then try again.'
						: 'We couldn’t save your password right now. Try again shortly.'
			});
		}
		clearJoinPasswordNeeded(event.cookies);
		redirect(303, JOIN_PATH);
	},

	accept: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, JOIN_PATH);
		const token = readJoinToken(event.cookies);
		if (!token) return fail(410, { unavailable: true });
		await acceptingState(event, session);

		const idempotencyKey = String((await event.request.formData()).get('idempotencyKey') ?? '');
		if (!IDEMPOTENCY_KEY_PATTERN.test(idempotencyKey)) {
			return fail(400, { message: 'That invitation can’t be accepted. Reload and try again.' });
		}
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				const api = yield* InvitationsApi;
				return yield* api.accept({ token, idempotencyKey });
			})
		);
		if (Exit.isFailure(exit)) {
			const failure = failureOf(exit);
			if (isBackendError(failure, 'invitation_unavailable')) {
				clearJoin(event.cookies);
				return fail(410, { unavailable: true });
			}
			if (isBackendError(failure, 'membership_exists')) {
				clearJoin(event.cookies);
				redirect(303, '/workspaces?switch');
			}
			if (isBackendError(failure, 'invitation_email_mismatch')) {
				// Forget the link so this account is not sent back here each time.
				clearJoin(event.cookies);
				return fail(403, {
					message:
						'This invitation was sent to a different email. Sign in with that email, then open the link again.',
					mismatch: true
				});
			}
			if (isBackendError(failure, 'email_unverified')) {
				return fail(403, { message: 'Confirm your email first, then try again.', idempotencyKey });
			}
			if (failure._tag === 'TransportError' && failure.status !== 401) {
				// Outcome unknown: the retry reuses the same key (W-00).
				return fail(503, { message: 'We couldn’t confirm that. Try again.', idempotencyKey });
			}
			redirectForFailure(failure);
		}

		clearJoin(event.cookies);
		// The first-use wizard (W-02) runs in the membership just created.
		writeOnboardingMembership(event.cookies, exit.value.membershipId, event.locals.secureCookies);
		redirect(303, '/onboarding');
	}
};
