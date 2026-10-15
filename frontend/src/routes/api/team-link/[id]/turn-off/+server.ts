// Turn off the office's team link (Blueprint 38; Paper TL02 "Turn off"). The
// PIN is sent only when the panel asked for it (step-up, A-05).
import { Effect, Schema } from 'effect';
import { TurnOffTeamLinkCommand } from '#lib/contract/app.js';
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
	let body: TurnOffTeamLinkCommand;
	try {
		body = Schema.decodeUnknownSync(TurnOffTeamLinkCommand)(await event.request.json());
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
				return yield* (yield* InvitationsApi).turnOffTeamLink(membershipId, event.params.id, input);
			})
		)
	);
	return respond(exit);
};
