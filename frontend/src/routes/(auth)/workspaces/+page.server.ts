// Workspace picker (A-02, decisions 47/48) with the in-app "Invitations for
// you" list (W-03 owner decision 8; Paper "App — Screens v3" G10–G12). The
// selected membership lives in an HttpOnly cookie, never in the URL; the server
// validates it with GET /capabilities before storing it.

import { fail, redirect, type RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { IDEMPOTENCY_KEY_PATTERN, UUID_PATTERN } from '#lib/contract/common.js';
import { pathForGateCode } from '#lib/gate.js';
import { isSelectable, type Workspace } from '#lib/contract/org.js';
import { InvitationsApi, OrgApi } from '#lib/server/apis.js';
import type { VerifiedSession } from '#lib/server/auth.js';
import { clearWorkspace, readWorkspace, writeWorkspace } from '#lib/server/cookies.js';
import {
	callOrRedirect,
	expectGate,
	failureOf,
	isBackendError,
	redirectForFailure
} from '#lib/server/flow.js';
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

/**
 * Pending invitations for this person. A failure here must not block opening an
 * existing workspace: gate/auth failures still redirect, anything else hides
 * the list.
 */
async function listInvitations(event: RequestEvent, session: VerifiedSession) {
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const api = yield* InvitationsApi;
			return yield* api.mine;
		})
	);
	if (Exit.isSuccess(exit)) return exit.value;
	const failure = failureOf(exit);
	const gate = failure._tag === 'BackendError' && pathForGateCode(failure.code);
	if (gate || (failure._tag === 'TransportError' && failure.status === 401)) {
		redirectForFailure(failure);
	}
	return [];
}

/** One key per accept attempt; a failed post hands the same key back for the retry. */
const newIdempotencyKey = () => crypto.randomUUID().replaceAll('-', '');

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
	const [workspaces, invitations] = await Promise.all([
		listWorkspaces(event, session),
		listInvitations(event, session)
	]);
	const selectable = workspaces.filter(isSelectable);
	const switching = event.url.searchParams.has('switch');

	// Pending invitations keep the picker open so the person sees them.
	if (!switching && invitations.length === 0) {
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
		})),
		invitations: invitations.map((i) => ({
			invitationId: i.invitationId,
			tenantName: i.tenantName,
			officeName: i.officeName,
			role: i.role,
			idempotencyKey: newIdempotencyKey()
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
	},

	accept: async (event) => {
		const { session } = await expectGate(event, 'ready');
		const form = await event.request.formData();
		const invitationId = String(form.get('invitationId') ?? '');
		const idempotencyKey = String(form.get('idempotencyKey') ?? '');
		if (!UUID_PATTERN.test(invitationId) || !IDEMPOTENCY_KEY_PATTERN.test(idempotencyKey)) {
			return fail(400, { message: 'That invitation can’t be accepted. Reload and try again.' });
		}
		const exit = await runApi(
			event,
			session,
			Effect.gen(function* () {
				const api = yield* InvitationsApi;
				return yield* api.accept({ invitationId, idempotencyKey });
			})
		);
		if (Exit.isFailure(exit)) {
			const failure = failureOf(exit);
			if (isBackendError(failure, 'invitation_unavailable')) {
				return fail(410, { message: 'This invitation is no longer available.' });
			}
			if (failure._tag === 'TransportError' && failure.status !== 401) {
				// Outcome unknown: the retry reuses the same key (W-00).
				return fail(503, {
					message: 'We couldn’t confirm that. Try again.',
					retry: { invitationId, idempotencyKey }
				});
			}
			redirectForFailure(failure);
		}

		const accepted = exit.value;
		const workspaces = await listWorkspaces(event, session);
		const joined = workspaces.find(
			(w) => w.membershipId === accepted.membershipId && isSelectable(w)
		);
		if (joined && (await select(event, session, joined))) redirect(303, APP_PATH);
		redirect(303, '/workspaces?switch');
	}
};
