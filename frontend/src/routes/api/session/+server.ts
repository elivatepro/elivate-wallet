// GET /api/session: who is signed in, the gate, and the selected workspace.
// Blueprint 20: one backend read (api.app_bootstrap) instead of five in a row;
// the reply is the same SessionView as before.
import { Effect, Exit, Option, Schema } from 'effect';
import { failureOf, isBackendError } from '#lib/server/flow.js';
import type { SessionView } from '#lib/contract/app.js';
import { Profile, shownName } from '#lib/contract/identity.js';
import { Brand } from '#lib/contract/settings.js';
import { SecurityApi } from '#lib/server/apis.js';
import { clearWorkspace, readWorkspace } from '#lib/server/cookies.js';
import { respond, respondError, unauthenticated } from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import { clearWho, writeWho } from '#lib/server/who.js';
import { appServerSecret } from '#lib/server/config.js';
import type { RequestHandler } from './$types';

// The name and the brand are niceties: a part that does not decode is left
// out, never the session.
const decodeProfile = Schema.decodeUnknownOption(Profile);
const decodeBrand = Schema.decodeUnknownOption(Brand);

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);

	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const boot = yield* (yield* SecurityApi).bootstrap(membershipId);
			const base: SessionView = {
				state: boot.state,
				workspace: null,
				capabilities: null,
				profile: null
			};
			if (boot.state.gate !== 'ready') return base;
			const profile = Option.getOrNull(
				Option.map(decodeProfile(boot.profile), (p) => ({
					name: shownName(p),
					hasPhoto: p.hasPhoto
				}))
			);
			const view: SessionView = { ...base, profile };
			if (!boot.workspace || !boot.capabilities) return view;
			// Blueprint 17: Ember is the fallback when the brand is unavailable.
			const brand = Option.getOrNull(decodeBrand(boot.brand));
			return { ...view, workspace: boot.workspace, capabilities: boot.capabilities, brand };
		})
	);
	// workspace_invalid: the cookie no longer names a usable workspace.
	if (Exit.isFailure(exit) && isBackendError(failureOf(exit), 'workspace_invalid')) {
		clearWorkspace(event.cookies);
	}
	// Blueprint 20 B6: keep the device-cache guard in step with the confirmed
	// person and workspace (refreshes its lifetime on every app open).
	if (Exit.isSuccess(exit)) {
		const workspace = exit.value.workspace;
		if (workspace) {
			await writeWho(
				event.cookies,
				appServerSecret(),
				session.userId,
				workspace.membershipId,
				event.locals.secureCookies
			);
		} else clearWho(event.cookies);
	}
	return respond(exit);
};
