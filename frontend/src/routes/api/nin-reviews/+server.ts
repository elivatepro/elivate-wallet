// Pending NIN reviews this workspace may decide (Blueprint 06 Q4: President
// Team of the network, or World Team at/above the person's office).
import { Effect } from 'effect';
import { IdentityApi } from '#lib/server/apis-identity.js';
import { readWorkspace } from '#lib/server/cookies.js';
import { respond, respondError, unauthenticated, workspaceChanged } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	return respond(
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* IdentityApi).reviews(membershipId);
			})
		)
	);
};
