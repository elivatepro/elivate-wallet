// The bell (Blueprint 13): items for the selected workspace's network plus
// personal ones, with live "needs your action" tasks first.
import { Effect } from 'effect';
import { BackendError } from '#lib/contract/errors.js';
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

const invalid = (field: string) =>
	new BackendError({
		status: 400,
		code: 'validation_error',
		message: 'The request is invalid.',
		retryable: false,
		details: { field },
		requestId: null
	});

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	// The tab's workspace must still be the selected one (another tab may have switched).
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId || !workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const params = event.url.searchParams;
	const view = params.get('view') ?? 'all';
	if (view !== 'all' && view !== 'unread') return respondError(invalid('view'));
	const cursor = params.get('cursor') ?? undefined;
	if (cursor !== undefined && !/^[A-Za-z0-9+/=]{1,400}$/.test(cursor)) {
		return respondError(invalid('cursor'));
	}
	const limitText = params.get('limit');
	const limit = limitText === null ? undefined : Number(limitText);
	if (limit !== undefined && !(Number.isInteger(limit) && limit >= 1 && limit <= 100)) {
		return respondError(invalid('limit'));
	}
	return respond(
		await runApi(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* IdentityApi).notifications(membershipId, {
					view,
					...(cursor ? { cursor } : {}),
					...(limit ? { limit } : {})
				});
			})
		)
	);
};
