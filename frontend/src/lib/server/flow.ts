// Gate handling for server-rendered auth/onboarding routes (plan §5.7).

import { error, redirect, type RequestEvent } from '@sveltejs/kit';
import { Cause, Effect, Exit, Option } from 'effect';
import type { BackendError } from '#lib/contract/errors.js';
import type { Gate, SecurityState } from '#lib/contract/security.js';
import { GATE_PATHS, pathForGateCode, SIGN_IN_PATH } from '#lib/gate.js';
import { SecurityApi } from './apis';
import type { VerifiedSession } from './auth';
import type { EdgeFailure } from './edge';
import { runApi, type ApiServices } from './request';

/** The verified session, or a redirect to sign-in. */
export async function requireSession(event: RequestEvent): Promise<VerifiedSession> {
	const session = await event.locals.session();
	if (!session) redirect(303, SIGN_IN_PATH);
	return session;
}

/** Extracts the typed failure from an Exit (defects are rethrown). */
export function failureOf<A>(exit: Exit.Exit<A, EdgeFailure>): EdgeFailure {
	if (Exit.isSuccess(exit)) throw new Error('expected a failure');
	const failure = Cause.findErrorOption(exit.cause);
	if (Option.isSome(failure)) return failure.value;
	throw Cause.squash(exit.cause);
}

/**
 * Sends gate/auth failures to their page. Anything else becomes a safe 503:
 * transport problems and contract violations never show raw details.
 */
export function redirectForFailure(failure: EdgeFailure): never {
	if (failure._tag === 'BackendError') {
		const path = pathForGateCode(failure.code);
		if (path) redirect(303, path);
	}
	if (failure._tag === 'TransportError' && failure.status === 401) redirect(303, SIGN_IN_PATH);
	if (failure._tag === 'ContractViolation') {
		// Route pattern + backend requestId only (plan §5.9).
		console.error(
			JSON.stringify({ route: failure.route, requestId: failure.requestId, contract: 'violation' })
		);
	}
	error(503, 'Wallet is unavailable right now. Try again shortly.');
}

/** Runs an API program for the signed-in person; gate failures redirect. */
export async function callOrRedirect<A>(
	event: RequestEvent,
	session: VerifiedSession,
	program: Effect.Effect<A, EdgeFailure, ApiServices>
): Promise<A> {
	const exit = await runApi(event, session, program);
	if (Exit.isSuccess(exit)) return exit.value;
	redirectForFailure(failureOf(exit));
}

/** Current security state; signed-out people go to sign-in. */
export async function loadState(event: RequestEvent): Promise<{
	session: VerifiedSession;
	state: SecurityState;
}> {
	const session = await requireSession(event);
	const state = await callOrRedirect(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* SecurityApi;
			return yield* api.state;
		})
	);
	return { session, state };
}

/** The page belongs to `gates`; any other gate redirects to its own page. */
export async function expectGate(
	event: RequestEvent,
	...gates: Gate[]
): Promise<{ session: VerifiedSession; state: SecurityState }> {
	const result = await loadState(event);
	if (!gates.includes(result.state.gate)) redirect(303, GATE_PATHS[result.state.gate]);
	return result;
}

export const isBackendError = (failure: EdgeFailure, code: BackendError['code']): boolean =>
	failure._tag === 'BackendError' && failure.code === code;
