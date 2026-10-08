// Workspace picker (A-02, decisions 47/48). The selected membership lives in an
// HttpOnly cookie, never in the URL; the server validates it with
// GET /capabilities before storing it.

import { fail, redirect, type RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { isSelectable, type Workspace } from '#lib/contract/org.js';
import { OrgApi } from '#lib/server/apis.js';
import type { VerifiedSession } from '#lib/server/auth.js';
import { clearWorkspace, readWorkspace, writeWorkspace } from '#lib/server/cookies.js';
import { callOrRedirect, expectGate, failureOf, redirectForFailure } from '#lib/server/flow.js';
import { runApi } from '#lib/server/request.js';
import type { Actions, PageServerLoad } from './$types';

const APP_PATH = '/app';

const listWorkspaces = (event: RequestEvent, session: VerifiedSession) =>
	callOrRedirect(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* OrgApi;
			return yield* api.workspaces;
		})
	);

/** Validates with the server, then stores the choice. Returns false when refused. */
async function select(
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
		return true;
	}
	const failure = failureOf(exit);
	if (failure._tag === 'BackendError' && failure.code === 'workspace_invalid') {
		clearWorkspace(event.cookies);
		return false;
	}
	redirectForFailure(failure);
}

export const load: PageServerLoad = async (event) => {
	const { session, state } = await expectGate(event, 'ready');
	const workspaces = await listWorkspaces(event, session);
	const selectable = workspaces.filter(isSelectable);
	const switching = event.url.searchParams.has('switch');

	if (!switching) {
		// A still-valid earlier choice skips the picker (plan §7.2 step 3).
		const current = readWorkspace(event.cookies);
		const remembered = selectable.find((w) => w.membershipId === current);
		if (remembered && (await select(event, session, remembered))) redirect(303, APP_PATH);
		// Exactly one workspace is opened automatically (decision 48).
		const only = selectable.length === 1 ? selectable[0] : undefined;
		if (only && (await select(event, session, only))) {
			redirect(303, APP_PATH);
		}
	}

	return {
		uid: state.uid,
		workspaces: workspaces.map((w) => ({
			membershipId: w.membershipId,
			tenantName: w.tenantName,
			officeName: w.officeName,
			role: w.role,
			tenantStatus: w.tenantStatus,
			selectable: isSelectable(w)
		}))
	};
};

export const actions: Actions = {
	select: async (event) => {
		const { session } = await expectGate(event, 'ready');
		const form = await event.request.formData();
		const membershipId = String(form.get('membershipId') ?? '');
		const workspaces = await listWorkspaces(event, session);
		const chosen = workspaces.find((w) => w.membershipId === membershipId && isSelectable(w));
		if (!chosen || !(await select(event, session, chosen))) {
			return fail(409, { message: 'That workspace can’t be opened. Choose another.' });
		}
		redirect(303, APP_PATH);
	}
};
