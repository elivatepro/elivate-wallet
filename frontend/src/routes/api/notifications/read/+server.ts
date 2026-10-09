// Mark bell items read (Blueprint 13): the given ids or everything shown in
// this workspace. Idempotent; the backend only touches the caller's own items.
import { Effect, Schema } from 'effect';
import { BackendError } from '#lib/contract/errors.js';
import { MarkReadCommand } from '#lib/contract/notifications.js';
import { IdentityApi } from '#lib/server/apis-identity.js';
import { readWorkspace } from '#lib/server/cookies.js';
import {
	respond,
	respondError,
	unauthenticated,
	workspaceChanged,
	workspaceEchoMatches
} from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;
	let body: MarkReadCommand;
	try {
		body = Schema.decodeUnknownSync(MarkReadCommand, { onExcessProperty: 'error' })(
			await event.request.json()
		);
	} catch {
		return respondError(
			new BackendError({
				status: 400,
				code: 'validation_error',
				message: 'The request is invalid.',
				retryable: false,
				details: { field: 'body' },
				requestId: null
			})
		);
	}
	return respond(
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* IdentityApi).markRead(membershipId, body);
			})
		)
	);
};
