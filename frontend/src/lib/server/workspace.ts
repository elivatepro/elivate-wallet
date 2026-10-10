// Opening a workspace (A-02, decisions 47/48): the server validates the
// membership with GET /capabilities before storing it in the HttpOnly cookie.
// Shared by the workspace picker and the join flow.

import type { RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { isSelectable, type Workspace } from '#lib/contract/org.js';
import { OrgApi } from './apis';
import type { VerifiedSession } from './auth';
import { clearWorkspace, writeWorkspace } from './cookies';
import { appServerSecret } from './config';
import { callOrRedirect, failureOf, redirectForFailure } from './flow';
import { runApi } from './request';
import { writeWho } from './who';

export const listWorkspaces = (event: RequestEvent, session: VerifiedSession) =>
	callOrRedirect(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* OrgApi;
			return yield* api.workspaces;
		})
	);

/** Validates with the server, then stores the choice. Returns false when refused. */
export async function selectWorkspace(
	event: RequestEvent,
	session: VerifiedSession,
	workspace: Workspace
): Promise<boolean> {
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* OrgApi;
			return yield* api.capabilities(workspace.membershipId);
		})
	);
	if (Exit.isSuccess(exit)) {
		writeWorkspace(event.cookies, workspace.membershipId, event.locals.secureCookies);
		// Blueprint 20 B6: the device-cache guard follows the chosen workspace.
		await writeWho(
			event.cookies,
			appServerSecret(),
			session.userId,
			workspace.membershipId,
			event.locals.secureCookies
		);
		return true;
	}
	const failure = failureOf(exit);
	if (failure._tag === 'BackendError' && failure.code === 'workspace_invalid') {
		clearWorkspace(event.cookies);
		return false;
	}
	redirectForFailure(failure);
}

/** Opens the membership just created by an accepted invitation, when it can be opened. */
export async function openMembership(
	event: RequestEvent,
	session: VerifiedSession,
	membershipId: string
): Promise<boolean> {
	const workspaces = await listWorkspaces(event, session);
	const joined = workspaces.find((w) => w.membershipId === membershipId && isSelectable(w));
	return joined ? selectWorkspace(event, session, joined) : false;
}

/** One key per command attempt; a failed post hands the same key back for the retry. */
export const newIdempotencyKey = () => crypto.randomUUID().replaceAll('-', '');
