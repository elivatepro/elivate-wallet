// Founder invitation link (Blueprint 19; Paper "Authentication v2" 08, 09, 10
// with founder wording). The same flow as `/join`: the page posts `#t=` once
// (`claim`), the server checks it and keeps it in an HttpOnly cookie, then:
//   signed out          → masked bound email + "Verify email"
//   signed in, new      → first password (the verification email created the account)
//   signed in           → accept (makes the account a founder), gate `ready`
//                          or `pin_setup_required`, then network setup
// Every unknown/expired/replaced/used token gets the same "unavailable" page.

import { fail, redirect, type RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { IDEMPOTENCY_KEY_PATTERN } from '#lib/contract/common.js';
import { INVITATION_TOKEN_PATTERN } from '#lib/contract/invitations.js';
import { GATE_PATHS } from '#lib/gate.js';
import { maskEmail } from '#lib/labels.js';
import { FoundersApi } from '#lib/server/apis-founders.js';
import { authFailureFrom, type VerifiedSession } from '#lib/server/auth.js';
import {
	clearFounder,
	clearFounderPasswordNeeded,
	founderPasswordNeeded,
	readFounderToken,
	writeFounderToken
} from '#lib/server/cookies.js';
import { failureOf, isBackendError, loadState, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import { newIdempotencyKey } from '#lib/server/workspace.js';
import { MAX_PASSWORD, MIN_PASSWORD } from '../credentials';
import type { Actions, PageServerLoad } from './$types';

const FOUNDER_PATH = '/founder';

async function acceptingState(event: RequestEvent, session: VerifiedSession) {
	const { state } = await loadState(event);
	if (state.gate === 'pin_required') {
		redirect(303, `${GATE_PATHS.pin_required}?next=${FOUNDER_PATH}`);
	}
	if (state.gate === 'pin_locked') redirect(303, GATE_PATHS.pin_locked);
	return { session, state };
}

/** POST /founder/preview without a session. `null` means unavailable (cookie cleared). */
async function preview(
	event: RequestEvent,
	token: string
): Promise<{ email: string; teamName: string } | null> {
	const exit = await runApi(
		event,
		null,
		Effect.gen(function* () {
			return yield* (yield* FoundersApi).preview(token);
		})
	);
	if (Exit.isSuccess(exit)) return exit.value;
	const failure = failureOf(exit);
	if (
		isBackendError(failure, 'invitation_unavailable') ||
		isBackendError(failure, 'validation_error')
	) {
		clearFounder(event.cookies);
		return null;
	}
	redirectForFailure(failure);
}

export const load: PageServerLoad = async (event) => {
	const token = readFounderToken(event.cookies);
	if (!token) return { mode: 'claim' as const };

	const found = await preview(event, token);
	if (found === null) return { mode: 'unavailable' as const };

	const session = await event.locals.session();
	if (!session) {
		return {
			mode: 'verify' as const,
			maskedEmail: maskEmail(found.email),
			teamName: found.teamName
		};
	}

	await acceptingState(event, session);
	if (founderPasswordNeeded(event.cookies)) {
		return { mode: 'password' as const, email: session.email ?? '' };
	}
	return {
		mode: 'accept' as const,
		email: session.email ?? '',
		teamName: found.teamName,
		idempotencyKey: newIdempotencyKey()
	};
};

export const actions: Actions = {
	claim: async (event) => {
		const form = await event.request.formData();
		const token = String(form.get('token') ?? '');
		if (!INVITATION_TOKEN_PATTERN.test(token)) {
			clearFounder(event.cookies);
			return fail(410, { unavailable: true });
		}
		if ((await preview(event, token)) === null) return fail(410, { unavailable: true });
		writeFounderToken(event.cookies, token, event.locals.secureCookies);
		redirect(303, FOUNDER_PATH);
	},

	verify: async (event) => {
		const token = readFounderToken(event.cookies);
		if (!token) return fail(410, { unavailable: true });
		const exit = await runApi(
			event,
			null,
			Effect.gen(function* () {
				return yield* (yield* FoundersApi).verifyEmail(token);
			})
		);
		if (Exit.isSuccess(exit)) return { sent: true };
		const failure = failureOf(exit);
		if (isBackendError(failure, 'invitation_unavailable')) {
			clearFounder(event.cookies);
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
		if (!session) redirect(303, FOUNDER_PATH);
		if (!founderPasswordNeeded(event.cookies)) redirect(303, FOUNDER_PATH);
		const password = String((await event.request.formData()).get('password') ?? '');
		if (password.length < MIN_PASSWORD) {
			return fail(400, { error: `Use at least ${MIN_PASSWORD} characters.` });
		}
		if (password.length > MAX_PASSWORD) return fail(400, { error: 'That password is too long.' });

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
		clearFounderPasswordNeeded(event.cookies);
		redirect(303, FOUNDER_PATH);
	},

	accept: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, FOUNDER_PATH);
		const token = readFounderToken(event.cookies);
		if (!token) return fail(410, { unavailable: true });
		const { state } = await acceptingState(event, session);

		const idempotencyKey = String((await event.request.formData()).get('idempotencyKey') ?? '');
		if (!IDEMPOTENCY_KEY_PATTERN.test(idempotencyKey)) {
			return fail(400, { message: 'That invitation can’t be accepted. Reload and try again.' });
		}
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* FoundersApi).accept({ token, idempotencyKey });
			})
		);
		if (Exit.isFailure(exit)) {
			const failure = failureOf(exit);
			if (isBackendError(failure, 'invitation_unavailable')) {
				clearFounder(event.cookies);
				return fail(410, { unavailable: true });
			}
			if (isBackendError(failure, 'invitation_email_mismatch')) {
				clearFounder(event.cookies);
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
				return fail(503, { message: 'We couldn’t confirm that. Try again.', idempotencyKey });
			}
			redirectForFailure(failure);
		}

		clearFounder(event.cookies);
		// A new account sets its PIN first, then names the network (W-19).
		redirect(303, state.gate === 'pin_setup_required' ? '/pin/setup?next=/setup' : '/setup');
	}
};
