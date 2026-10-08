// Same-origin JSON endpoints (decision 36): the signed-in PWA shell calls these;
// they forward to the Edge Functions with the HttpOnly session and relay the
// backend envelope. Only backend error codes are ever emitted.

import type { RequestEvent } from '@sveltejs/kit';
import { Exit } from 'effect';
import { failureBody, successBody } from '#lib/contract/envelope.js';
import { BackendError } from '#lib/contract/errors.js';
import { readWorkspace } from './cookies';
import type { EdgeFailure } from './edge';
import { failureOf } from './flow';

const headers = { 'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8' };

const local = (status: number, code: BackendError['code'], message: string, retryable = false) =>
	new BackendError({
		status,
		code,
		message,
		retryable,
		details: {},
		requestId: crypto.randomUUID()
	});

export const unauthenticated = () => local(401, 'authentication_required', 'Sign in to continue.');

/** A same-origin request body or query that does not match its schema. */
export const invalidRequest = (field: string) =>
	new BackendError({
		status: 400,
		code: 'validation_error',
		message: 'The request is invalid.',
		retryable: false,
		details: { field },
		requestId: null
	});

/** Maps any failure to a relayed envelope with an honest status. */
export function toBackendError(failure: EdgeFailure): BackendError {
	switch (failure._tag) {
		case 'BackendError':
			return failure;
		case 'TransportError':
			return failure.status === 401
				? unauthenticated()
				: local(502, 'internal_error', 'Something went wrong. Try again.', true);
		case 'ContractViolation':
			console.error(
				JSON.stringify({
					route: failure.route,
					requestId: failure.requestId,
					contract: 'violation'
				})
			);
			return local(502, 'internal_error', 'Something went wrong. Try again.');
	}
}

export function respond<A>(exit: Exit.Exit<A, EdgeFailure>): Response {
	if (Exit.isSuccess(exit)) {
		return new Response(JSON.stringify(successBody(exit.value, crypto.randomUUID())), {
			status: 200,
			headers
		});
	}
	return respondError(toBackendError(failureOf(exit)));
}

export function respondError(error: BackendError): Response {
	return new Response(JSON.stringify(failureBody(error)), { status: error.status, headers });
}

/**
 * Multi-tab safety for commands (decision 47, plan §5.8): every command carries
 * the workspace it was rendered for; a mismatch with the cookie is refused
 * before anything reaches the backend.
 */
export function workspaceEchoMatches(event: RequestEvent): boolean {
	const echoed = event.request.headers.get('x-ew-workspace');
	const current = readWorkspace(event.cookies);
	return !!echoed && !!current && echoed === current;
}

export const workspaceChanged = () =>
	local(403, 'workspace_invalid', 'Workspace changed in another tab. Reload to continue.');
