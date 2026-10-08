// Revoke an invitation (I02): reason 3–500; an accepted one answers `conflict`.
// The PIN is sent only when the dialog asked for it (step-up, A-05).
import { Effect, Schema } from 'effect';
import { RevokeCommand } from '#lib/contract/app.js';
import { InvitationsApi } from '#lib/server/apis.js';
import { readWorkspace } from '#lib/server/cookies.js';
import {
	invalidRequest,
	respond,
	respondError,
	unauthenticated,
	workspaceChanged,
	workspaceEchoMatches
} from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import { withPin } from '#lib/server/step-up.js';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;
	let body: RevokeCommand;
	try {
		body = Schema.decodeUnknownSync(RevokeCommand)(await event.request.json());
	} catch {
		return respondError(invalidRequest('body'));
	}
	const { pin, ...input } = body;
	const exit = await runApi(
		event,
		session,
		withPin(
			pin,
			Effect.gen(function* () {
				return yield* (yield* InvitationsApi).revoke(membershipId, event.params.id, input);
			})
		)
	);
	return respond(exit);
};
