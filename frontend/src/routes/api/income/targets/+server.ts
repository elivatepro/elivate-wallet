// Who the signed-in leader may record income for, plus the network's live split
// and currencies (W-08 step 1; Blueprint 09). One backend page per call.
import { Effect } from 'effect';
import { IncomeApi } from '#lib/server/apis-income.js';
import { readWorkspace } from '#lib/server/cookies.js';
import {
	invalidRequest,
	respond,
	respondError,
	unauthenticated,
	workspaceChanged
} from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	const params = event.url.searchParams;
	if ([...params.keys()].some((key) => key !== 'cursor'))
		return respondError(invalidRequest('query'));
	const cursor = params.get('cursor');
	if (cursor !== null && (cursor.length < 1 || cursor.length > 500)) {
		return respondError(invalidRequest('cursor'));
	}
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* IncomeApi).targets(membershipId, cursor);
		})
	);
	return respond(exit);
};
