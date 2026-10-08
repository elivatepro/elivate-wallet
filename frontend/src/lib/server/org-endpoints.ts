// Shared plumbing for the /api/org/* endpoints (Blueprint 07). Reads: signed
// in, the workspace cookie, then one Effect program. Commands: the
// relayCommand recipe (workspace echo, body schema, optional dialog PIN) and
// then one `org` route. Only backend error codes are ever emitted.

import type { RequestEvent } from '@sveltejs/kit';
import { Effect, type Schema } from 'effect';
import { UUID_PATTERN } from '#lib/contract/common.js';
import type { Workspace } from '#lib/contract/org.js';
import { OrgApi } from './apis';
import { OrgAdminApi } from './apis-org';
import { relayCommand } from './command';
import { readWorkspace } from './cookies';
import type { EdgeFailure, EdgeRoute } from './edge';
import { invalidRequest, respond, respondError, unauthenticated, workspaceChanged } from './relay';
import { runApi, type ApiServices } from './request';

export async function orgRead<A>(
	event: RequestEvent,
	program: (membershipId: string) => Effect.Effect<A, EdgeFailure, ApiServices>
): Promise<Response> {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	return respond(await runApi(event, session, program(membershipId)));
}

/** POSTs one `org` command; the PIN never reaches the Edge body. */
export function orgCommand<S extends Schema.ConstraintDecoder<{ pin?: string }>>(
	event: RequestEvent,
	schema: S,
	route: (body: S['Type']) => EdgeRoute
): Promise<Response> {
	return relayCommand(event, schema, (membershipId, body) =>
		Effect.gen(function* () {
			const rest: Record<string, unknown> = { ...(body as Record<string, unknown>) };
			delete rest.pin;
			return yield* (yield* OrgAdminApi).command(route(body), rest, membershipId);
		})
	);
}

/** A path id that is not a UUID is a bad request, never a backend call. */
export function pathId(event: RequestEvent): string | Response {
	const value = (event.params as Record<string, string | undefined>).id ?? '';
	return UUID_PATTERN.test(value) ? value : respondError(invalidRequest('id'));
}

/** The selected workspace's own membership (role, office). */
export const currentWorkspace = (membershipId: string) =>
	Effect.gen(function* () {
		const all = yield* (yield* OrgApi).workspaces;
		return all.find((w) => w.membershipId === membershipId) ?? null;
	}) as Effect.Effect<Workspace | null, EdgeFailure, ApiServices>;

/**
 * Follows `nextCursor` until the list ends or `maxPages` pages (100 rows
 * each) were read; `truncated` says whether more remain.
 */
export const allPages = <T>(
	page: (
		cursor: string | null
	) => Effect.Effect<
		{ items: ReadonlyArray<T>; nextCursor: string | null },
		EdgeFailure,
		ApiServices
	>,
	maxPages = 10
): Effect.Effect<{ items: T[]; truncated: boolean }, EdgeFailure, ApiServices> =>
	Effect.gen(function* () {
		const items: T[] = [];
		let cursor: string | null = null;
		let pages = 0;
		do {
			const next: { items: ReadonlyArray<T>; nextCursor: string | null } = yield* page(cursor);
			items.push(...next.items);
			cursor = next.nextCursor;
			pages += 1;
		} while (cursor && pages < maxPages);
		return { items, truncated: cursor !== null };
	});
