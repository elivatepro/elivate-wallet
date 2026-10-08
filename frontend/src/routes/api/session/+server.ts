import { Effect, Exit } from 'effect';
import { failureOf, isBackendError } from '#lib/server/flow.js';
import type { SessionView } from '#lib/contract/app.js';
import { OrgApi, SecurityApi } from '#lib/server/apis.js';
import { clearWorkspace, readWorkspace } from '#lib/server/cookies.js';
import { respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);

	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const security = yield* SecurityApi;
			const org = yield* OrgApi;
			const state = yield* security.state;
			const view: SessionView = { state, workspace: null, capabilities: null };
			if (state.gate !== 'ready' || !membershipId) return view;
			const workspaces = yield* org.workspaces;
			const workspace = workspaces.find((w) => w.membershipId === membershipId) ?? null;
			if (!workspace) return view;
			const capabilities = yield* org.capabilities(membershipId);
			return { ...view, workspace, capabilities };
		})
	);
	// workspace_invalid: the cookie no longer names a usable workspace.
	if (Exit.isFailure(exit) && isBackendError(failureOf(exit), 'workspace_invalid')) {
		clearWorkspace(event.cookies);
	}
	return respond(exit);
};
