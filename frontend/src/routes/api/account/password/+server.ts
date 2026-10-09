// Change the password while signed in (Blueprint 14; Paper Z08/Z09; owner
// decision 2026-10-09: the PIN only, no current password). Three steps:
// the backend checks the PIN (same 5 tries as everywhere), Supabase Auth
// saves the password for this session (supported path; Auth also signs out
// every other session), then the backend records it (audit, A06 email, bell).
// The password and PIN travel only in this POST body: never logged, cached
// or put in a URL. Never retried.
import { Effect, Exit, Schema } from 'effect';
import { ChangePasswordCommand } from '#lib/contract/account.js';
import { BackendError } from '#lib/contract/errors.js';
import { SecurityApi } from '#lib/server/apis.js';
import { authFailureFrom } from '#lib/server/auth.js';
import { invalidRequest } from '#lib/server/command.js';
import { respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import { MAX_PASSWORD, MIN_PASSWORD } from '../../../(auth)/credentials';
import type { RequestHandler } from './$types';

const passwordProblem = (
	reason: string,
	status = 400,
	code: BackendError['code'] = 'validation_error'
) =>
	new BackendError({
		status,
		code,
		message: 'The password was not changed.',
		retryable: false,
		details: { field: 'password', reason },
		requestId: null
	});

export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!event.request.headers.get('content-type')?.startsWith('application/json')) {
		return respondError(invalidRequest('body'));
	}
	let body: ChangePasswordCommand;
	try {
		body = Schema.decodeUnknownSync(ChangePasswordCommand)(await event.request.json());
	} catch {
		return respondError(invalidRequest('body'));
	}
	if (body.password.length < MIN_PASSWORD) return respondError(passwordProblem('too_short'));
	if (body.password.length > MAX_PASSWORD) return respondError(passwordProblem('too_long'));

	// 1. The PIN (a wrong one is counted and committed by the backend).
	const authorized = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* SecurityApi).authorizePasswordChange({ pin: body.pin });
		})
	);
	if (Exit.isFailure(authorized)) return respond(authorized);

	// 2. Supabase Auth saves the password for this session.
	const { error } = await event.locals.supabase().auth.updateUser({ password: body.password });
	if (error) {
		if (error.code === 'same_password') return respondError(passwordProblem('same_password'));
		const failure = authFailureFrom(error);
		if (failure.kind === 'weak_password') return respondError(passwordProblem('weak_password'));
		if (failure.kind === 'rate_limited') {
			return respondError(passwordProblem('rate_limited', 429, 'rate_limited'));
		}
		return respondError(passwordProblem('unavailable', 503, 'internal_error'));
	}

	// 3. Record it. The password has changed either way, so a failure here
	// still answers success (the email and audit are what would be missing).
	const recorded = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* SecurityApi).recordPasswordChange({
				changeId: authorized.value.changeId
			});
		})
	);
	if (Exit.isSuccess(recorded)) return respond(recorded);
	return respond(Exit.succeed({ changedAt: new Date().toISOString() }));
};
