// Joining by team link (Blueprint 38; Paper "Team links v11" TL03–TL05). The
// code came from `/j/<code>` and sits in the HttpOnly team cookie. By state:
//   no code, or the link no longer works → unavailable (TL04, one answer)
//   signed out → email + new password (Turnstile), then "check your inbox";
//                the confirmation email returns here through /auth/confirm
//   signed in → "Signed in as …" and Join (gate `ready` or `pin_setup_required`)
// Joining makes the person a Member of the link's office and starts the
// first-use wizard in that membership.

import { fail, redirect, type RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { IDEMPOTENCY_KEY_PATTERN } from '#lib/contract/common.js';
import type { TeamLinkPreview } from '#lib/contract/invitations.js';
import { GATE_PATHS } from '#lib/gate.js';
import { InvitationsApi } from '#lib/server/apis.js';
import { authFailureFrom } from '#lib/server/auth.js';
import { clearTeamCode, readTeamCode } from '#lib/server/cookies.js';
import { failureOf, isBackendError, loadState, redirectForFailure } from '#lib/server/flow.js';
import { humanCheck, turnstileSiteKey } from '#lib/server/human-check.js';
import { writeOnboardingMembership } from '#lib/server/onboarding.js';
import { runApi } from '#lib/server/request.js';
import { turnstileMessage } from '#lib/server/turnstile.js';
import { newIdempotencyKey } from '#lib/server/workspace.js';
import { authMessage, MIN_PASSWORD, readCredentials, type CredentialErrors } from '../credentials';
import type { Actions, PageServerLoad } from './$types';

const PATH = '/team-join';

/** POST /team-link/preview. `null` means unavailable (cookie cleared). */
async function preview(event: RequestEvent, code: string): Promise<TeamLinkPreview | null> {
	const exit = await runApi(
		event,
		null,
		Effect.gen(function* () {
			return yield* (yield* InvitationsApi).teamLinkPreview(code);
		})
	);
	if (Exit.isSuccess(exit)) return exit.value;
	const failure = failureOf(exit);
	if (
		isBackendError(failure, 'invitation_unavailable') ||
		isBackendError(failure, 'validation_error')
	) {
		clearTeamCode(event.cookies);
		return null;
	}
	redirectForFailure(failure);
}

/** Gates that may join (Blueprint 03 Q7, as for invitations). */
async function joiningState(event: RequestEvent) {
	const { state } = await loadState(event);
	if (state.gate === 'pin_required') redirect(303, `${GATE_PATHS.pin_required}?next=${PATH}`);
	if (state.gate === 'pin_locked') redirect(303, GATE_PATHS.pin_locked);
}

export const load: PageServerLoad = async (event) => {
	const code = readTeamCode(event.cookies);
	if (!code) return { mode: 'unavailable' as const };
	const team = await preview(event, code);
	if (!team) return { mode: 'unavailable' as const };

	const session = await event.locals.session();
	if (!session) {
		return { mode: 'signup' as const, team, turnstileSiteKey: turnstileSiteKey() };
	}
	await joiningState(event);
	return {
		mode: 'join' as const,
		team,
		email: session.email ?? '',
		idempotencyKey: newIdempotencyKey()
	};
};

export const actions: Actions = {
	signup: async (event) => {
		if (!readTeamCode(event.cookies)) return fail(410, { unavailable: true });
		const form = await event.request.formData();
		const credentials = readCredentials(form);
		if (!credentials.ok) return fail(400, { email: credentials.email, errors: credentials.errors });
		const { email, password } = credentials;
		const weak: CredentialErrors = { password: authMessage('weak_password', 'sign-up') };
		if (password.length < MIN_PASSWORD) return fail(400, { email, errors: weak });
		// Turnstile before Auth creates anything or sends email (Blueprint 10).
		const human = await humanCheck(event, form, 'sign-up');
		if (!human.ok) {
			return fail(human.reason === 'unavailable' ? 503 : 400, {
				email,
				message: turnstileMessage(human)
			});
		}

		const { error } = await event.locals.supabase().auth.signUp({
			email,
			password,
			options: { emailRedirectTo: new URL('/auth/confirm', event.url).toString() }
		});
		if (error) {
			const failure = authFailureFrom(error);
			if (failure.kind === 'weak_password') return fail(400, { email, errors: weak });
			if (failure.kind === 'rate_limited' || failure.kind === 'unavailable') {
				return fail(failure.kind === 'rate_limited' ? 429 : 503, {
					email,
					message: authMessage(failure.kind, 'sign-up')
				});
			}
			// Anything else (including an address that already has an account)
			// gets the same answer as success (W-01).
		}
		return { sent: true, email };
	},

	join: async (event) => {
		const session = await event.locals.session();
		if (!session) redirect(303, PATH);
		const code = readTeamCode(event.cookies);
		if (!code) return fail(410, { unavailable: true });
		await joiningState(event);

		const idempotencyKey = String((await event.request.formData()).get('idempotencyKey') ?? '');
		if (!IDEMPOTENCY_KEY_PATTERN.test(idempotencyKey)) {
			return fail(400, { message: 'That didn’t go through. Reload and try again.' });
		}
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* InvitationsApi).joinTeamLink({ code, idempotencyKey });
			})
		);
		if (Exit.isFailure(exit)) {
			const failure = failureOf(exit);
			if (isBackendError(failure, 'invitation_unavailable')) {
				clearTeamCode(event.cookies);
				return fail(410, { unavailable: true });
			}
			if (isBackendError(failure, 'membership_exists')) {
				clearTeamCode(event.cookies);
				redirect(303, '/workspaces?switch');
			}
			if (isBackendError(failure, 'email_unverified')) {
				return fail(403, { message: 'Confirm your email first, then try again.', idempotencyKey });
			}
			if (
				failure._tag === 'BackendError' &&
				failure.code === 'conflict' &&
				failure.details.reason === 'seat_limit_reached'
			) {
				return fail(409, {
					message: 'This team is full right now. Ask the person who shared the link.'
				});
			}
			if (failure._tag === 'TransportError' && failure.status !== 401) {
				// Outcome unknown: the retry reuses the same key (W-00).
				return fail(503, { message: 'We couldn’t confirm that. Try again.', idempotencyKey });
			}
			redirectForFailure(failure);
		}

		clearTeamCode(event.cookies);
		// The first-use wizard (W-02) runs in the membership just created.
		writeOnboardingMembership(event.cookies, exit.value.membershipId, event.locals.secureCookies);
		redirect(303, '/onboarding');
	}
};
