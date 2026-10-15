// The office's team link (Blueprint 38; Paper TL01/TL02). GET ?officeId= reads
// it; POST makes a new one (replacing the office's link) with the PIN when the
// five-minute proof has lapsed. The link code is built by the Edge Function.
import { Effect, Schema } from 'effect';
import { CreateTeamLinkCommand } from '#lib/contract/app.js';
import { UUID_PATTERN } from '#lib/contract/common.js';
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

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	const officeId = event.url.searchParams.get('officeId');
	if (!officeId || !UUID_PATTERN.test(officeId)) return respondError(invalidRequest('query'));
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* InvitationsApi).teamLink(membershipId, officeId);
		})
	);
	return respond(exit);
};

export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;
	let body: CreateTeamLinkCommand;
	try {
		body = Schema.decodeUnknownSync(CreateTeamLinkCommand)(await event.request.json());
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
				return yield* (yield* InvitationsApi).createTeamLink(membershipId, input);
			})
		)
	);
	return respond(exit);
};
