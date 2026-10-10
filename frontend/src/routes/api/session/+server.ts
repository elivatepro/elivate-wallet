import { Effect, Exit } from 'effect';
import { failureOf, isBackendError } from '#lib/server/flow.js';
import type { SessionView } from '#lib/contract/app.js';
import { shownName } from '#lib/contract/identity.js';
import { IdentityApi } from '#lib/server/apis-identity.js';
import { OrgApi, SecurityApi } from '#lib/server/apis.js';
import { SettingsApi } from '#lib/server/apis-settings.js';
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
			const base: SessionView = { state, workspace: null, capabilities: null, profile: null };
			if (state.gate !== 'ready') return base;
			// The name is a nicety: any failure leaves it out, never the session.
			const profile = yield* (yield* IdentityApi).profile.pipe(
				Effect.map((p) => ({ name: shownName(p), hasPhoto: p.hasPhoto })),
				Effect.orElseSucceed(() => null)
			);
			const view: SessionView = { ...base, profile };
			if (!membershipId) return view;
			const workspaces = yield* org.workspaces;
			const workspace = workspaces.find((w) => w.membershipId === membershipId) ?? null;
			if (!workspace) return view;
			const capabilities = yield* org.capabilities(membershipId);
			// Blueprint 17: the brand is a nicety too; Ember is the fallback.
			const brand = yield* (yield* SettingsApi)
				.brand(membershipId)
				.pipe(Effect.orElseSucceed(() => null));
			return { ...view, workspace, capabilities, brand };
		})
	);
	// workspace_invalid: the cookie no longer names a usable workspace.
	if (Exit.isFailure(exit) && isBackendError(failureOf(exit), 'workspace_invalid')) {
		clearWorkspace(event.cookies);
	}
	return respond(exit);
};
