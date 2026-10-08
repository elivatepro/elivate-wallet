// One same-origin command (decision 36, plan §5.8), the PUT /api/split recipe
// shared by the payout endpoints: signed in, the workspace echo matches the
// cookie, the body decodes, the optional dialog PIN opens a fresh step-up,
// then the backend envelope is relayed as-is. Never retried here: on an
// unknown outcome the browser resubmits with the same idempotency key.

import type { RequestEvent } from '@sveltejs/kit';
import { Schema, type Effect } from 'effect';
import { BackendError } from '#lib/contract/errors.js';
import { readWorkspace } from './cookies';
import type { EdgeFailure } from './edge';
import {
	respond,
	respondError,
	unauthenticated,
	workspaceChanged,
	workspaceEchoMatches
} from './relay';
import { runApi, type ApiServices } from './request';
import { withPin } from './step-up';

export const invalidRequest = (field: string) =>
	new BackendError({
		status: 400,
		code: 'validation_error',
		message: 'The request is invalid.',
		retryable: false,
		details: { field },
		requestId: null
	});

export async function relayCommand<S extends Schema.ConstraintDecoder<{ pin?: string }>, A>(
	event: RequestEvent,
	schema: S,
	program: (membershipId: string, body: S['Type']) => Effect.Effect<A, EdgeFailure, ApiServices>
): Promise<Response> {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;
	let body: S['Type'];
	try {
		body = Schema.decodeUnknownSync(schema)(await event.request.json());
	} catch {
		return respondError(invalidRequest('body'));
	}
	return respond(await runApi(event, session, withPin(body.pin, program(membershipId, body))));
}
