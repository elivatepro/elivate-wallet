// Team link (Blueprint 38 B1/B3): `/j/<code>`. A link that works keeps its code
// in the HttpOnly team cookie; either way the person lands on the clean
// `/team-join`, which shows the join page or the one "unavailable" answer
// (Paper TL03/TL04). The code is never logged or put in another URL.
import { redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { normalizeTeamCode } from '#lib/contract/invitations.js';
import { InvitationsApi } from '#lib/server/apis.js';
import { clearTeamCode, writeTeamCode } from '#lib/server/cookies.js';
import { failureOf, isBackendError, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const code = normalizeTeamCode(event.params.code);
	if (!code) {
		clearTeamCode(event.cookies);
		redirect(303, '/team-join');
	}
	const exit = await runApi(
		event,
		null,
		Effect.gen(function* () {
			return yield* (yield* InvitationsApi).teamLinkPreview(code);
		})
	);
	if (Exit.isSuccess(exit)) {
		writeTeamCode(event.cookies, code, event.locals.secureCookies);
		redirect(303, '/team-join');
	}
	const failure = failureOf(exit);
	if (
		isBackendError(failure, 'invitation_unavailable') ||
		isBackendError(failure, 'validation_error')
	) {
		clearTeamCode(event.cookies);
		redirect(303, '/team-join');
	}
	redirectForFailure(failure);
};
