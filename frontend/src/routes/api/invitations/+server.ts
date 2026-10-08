// Leaders' invitations for the selected workspace (Blueprint 03 B4; Paper I01).
// GET: one page (status filter, opaque cursor) plus, on the first page, the
// offices the leader can invite into. POST: create (leader roles: reason + PIN).
// Emails travel only in bodies; the link token never reaches this server.
import { Effect, Option, Schema } from 'effect';
import {
	CreateInvitationCommand,
	InvitationsQuery,
	type InvitationsView
} from '#lib/contract/app.js';
import { InvitationsApi, OrgApi } from '#lib/server/apis.js';
import { readWorkspace } from '#lib/server/cookies.js';
import {
	invalidRequest,
	respond,
	respondError,
	unauthenticated,
	workspaceChanged,
	workspaceEchoMatches
} from '#lib/server/relay.js';
import { runApi } from '#lib/server/request.js';
import { withPin } from '#lib/server/step-up.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	const raw: Record<string, string> = {};
	for (const field of ['status', 'cursor'] as const) {
		const value = event.url.searchParams.get(field);
		if (value !== null) raw[field] = value;
	}
	let query: typeof InvitationsQuery.Type;
	try {
		query = Schema.decodeUnknownSync(InvitationsQuery)(raw);
	} catch {
		return respondError(invalidRequest('query'));
	}
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			const invitations = yield* InvitationsApi;
			const org = yield* OrgApi;
			const [page, offices] = yield* Effect.all(
				[
					invitations.list(membershipId, query),
					// Later pages skip it; an unavailable offices read only hides "Invite".
					query.cursor ? Effect.succeedNone : Effect.option(org.activeOffices(membershipId))
				],
				{ concurrency: 2 }
			);
			return {
				page,
				offices: Option.match(offices, {
					onNone: () => null,
					onSome: (o) => o.items.map((x) => ({ officeId: x.id, name: x.name, type: x.type }))
				})
			} satisfies InvitationsView;
		})
	);
	return respond(exit);
};

export const POST: RequestHandler = async (event) => {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	if (!workspaceEchoMatches(event)) return respondError(workspaceChanged());
	const membershipId = readWorkspace(event.cookies)!;
	let body: CreateInvitationCommand;
	try {
		body = Schema.decodeUnknownSync(CreateInvitationCommand)(await event.request.json());
	} catch {
		return respondError(invalidRequest('body'));
	}
	const { pin, ...input } = body;
	const exit = await runApi(
		event,
		session,
		withPin(
			pin,
			Effect.gen(function* () {
				return yield* (yield* InvitationsApi).create(membershipId, input);
			})
		)
	);
	return respond(exit);
};
