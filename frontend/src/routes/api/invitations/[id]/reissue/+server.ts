// Resend an invitation (I01 "Resend link"): a fresh link, the old one stops
// working, the 7 days restart. Leader-role invitations need step-up (PIN).
import { Effect, Schema } from 'effect';
import { ReissueCommand } from '#lib/contract/app.js';
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
	let body: ReissueCommand;
	try {
		body = Schema.decodeUnknownSync(ReissueCommand)(await event.request.json());
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
				return yield* (yield* InvitationsApi).reissue(membershipId, event.params.id, input);
			})
		)
	);
	return respond(exit);
};
